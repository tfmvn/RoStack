# CodesAndRewards — MEMORY

Engineering notes for a future agent. Read this before touching anything in
`Source/`.

---

## 1. Purpose in one line

Three reward systems (redeem codes, a weekly daily streak, a session
playtime course) that share one config domain, one reward shape, and one
delivery pipeline, and that all commit in the same
tools → cash → slots → mark order — plus the two global pool selectors
that back them (`DailyRewardsWeek` for the weekly streak,
`PlaytimeRewardsDay` for the IST-day playtime pool).

---

## 2. How it actually works

### 2.1 The shared protocol

**Client → server: intent only.**

| Remote | Payload |
|---|---|
| `CodesAction` | `{ Action = 'Redeem', Code = '<string>' }` |
| `DailyRewardsAction` | `{ Action = 'State' \| 'Claim' \| 'ClaimAll', Day?: number }` |
| `PlaytimeRewardsAction` | `{ Action = 'State' \| 'Claim' \| 'ClaimAll', Index?: number }` |

`CodesService` additionally rejects any payload whose `Code` is not a string
or is longer than **64** characters (`handleAction`, `CodesService.lua:806`).
The `Day` and `Index` fields are **validated but never authoritative** — the
server recomputes them.

**Server → client.**

| Remote | Payload |
|---|---|
| `CodesResult` | `{ Success, Reason?, Message?, RewardText? }` |
| `DailyRewardsState` | `{ WeekId, PoolId, Day, ClaimableDay?, CanClaim, NextClaimAt, LastClaimAt, DayCount, Days: [{Day, State, Cash?, Eggs?, Tools?, Animals?}] }` |
| `DailyRewardsResult` | `{ Success, Reason?, Message?, Day?, RewardText? }` |
| `PlaytimeRewardsState` | `{ PoolId, DayId, Playtime, SessionStart, Completed, ClaimedCount, Version, Rewards: [{Index, RequiredPlaytime, State, Remaining, Cash?, Eggs?, Tools?, Animals?}] }` |
| `PlaytimeRewardsResult` | `{ Success, Reason?, Message?, Index?, RewardText?, State? }` |
| `CashCollected` | `{ Amount = '<BigNumber string>', NewMoney = '<BigNumber string>', Icon = MoneyIcon.Resolve() }` |

**Player-facing text and SFX never travel on the result remotes.** They go
through `NotificationService` (the `Notify` channel) with a message id from
`Config/Presentation/Messages.lua`. The result remotes carry **presentation
state only** (clear the TextBox, restore the Continue button, re-render the
cards).

### 2.2 The commit order (identical in all three)

```text
tools  ->  cash  ->  slot rewards  ->  mark redeemed/claimed
```

Why this order is safe:

- **Tools first.** `GearShopService.EnsureGearTool(player, id)` is
  **idempotent** — it no-ops when the tool is already present. A retry after
  a later failure can neither duplicate nor lose the tool.
- **Cash second.** `EconomyService.AddMoney(userId, amount, 'CodeReward',
  { ApplyMultiplier = false })` is validated before the call and cannot fail
  after it. `ApplyMultiplier = false` is deliberate — a code's cash is a
  literal amount, not a multiplied one.
- **Slot rewards third.** `deliverEgg` / `deliverAnimal` either land in a
  reserved free slot or are pushed onto `data.PendingCodeRewards`.
  **Pending counts as safely committed, never as a loss.**
- **Mark last.** `data.RedeemedCodes[norm] = count` /
  `slice.Day = claimDay + 1` / `persisted.Claimed[index] = true` happen
  only after everything above has landed.

The same order appears in `CodesService.RedeemInner` (`:665-780`),
`DailyRewardsService.commitDayRewards` (`:545-680`), and
`PlaytimeRewardsService.commitMilestone` (`:578-710`).

### 2.3 `CodesService`

**State**

| Local | Type | Meaning |
|---|---|---|
| `locks` | `{[string]: boolean}` | Per-player-per-code mutex. Key = `tostring(userId) .. '\0' .. norm`. |
| `delivering` | `{[number]: boolean}` | Pending-delivery reentrancy guard (the join hook, the sell hook, and the redeem path can overlap on one player). |
| `globalCounts` | `{[string]: number}` | Best-effort per-server global redemption counters. **Not persisted, not shared across servers.** |
| `started` | boolean | `Init()` was called. |

**`Redeem(player, codeText)`** (`:558`)

1. `norm = CodesConfig.NormalizeCode(codeText)` — trim + upper. `nil` →
   `unknown-code`.
2. If `locks[key]` → return `busy` (the first request owns the transaction).
3. `locks[key] = true`.
4. `pcall(RedeemInner)`; clear the lock.
5. On an uncaught error → `internal`.
6. On success → `FunnelService:LogStep(player, 'Rewards', 'CodeRedeemed',
   { code = norm })`. Promo code ids are public by design; no PII.
7. `pushResult(player, result)` — the result is pushed **once**, by `Redeem`.

**`RedeemInner(player, userId, norm)`** (`:600`) — the validation ladder, in
order. Each step returns `{ Success = false, Reason = ..., Message = ... }`
and notifies the player:

| # | Check | Reason on failure | Notification id |
|---|---|---|---|
| 1 | `CodesConfig.FindById(norm) ~= nil` | `unknown-code` | `Codes_InvalidCode` |
| 2 | `def.Enabled == true` | `disabled` | `Codes_CodeDisabled` |
| 3 | `os.time() < def.ExpiresAt` (or `ExpiresAt == nil`) | `expired` | `Codes_CodeExpired` |
| 4 | `playerServiceRef` + `economyServiceRef` set, and the profile loads | `no-systems` | `General_Generic` |
| 5 | `data.RedeemedCodes[norm] < (def.MaxPerPlayer or 1)` | `already-redeemed` | `Codes_AlreadyRedeemed` |
| 6 | `globalCounts[norm] < def.MaxGlobalRedemptions` (if set) | `disabled` | `Codes_CodeDisabled` |
| 7 | `#CodesConfig.ValidateRewards(def.Rewards) == 0` | `invalid-config` | `General_Generic` |
| 8 | slot services present if the reward has eggs/animals; gear service present if it has tools | `no-systems` | `General_Generic` |

Note that the **global cap reports the `disabled` reason**, not a distinct
one — deliberate, because the cap is best-effort.

Expiry is `os.time() >= ExpiresAt` → expired. `ExpiresAt = 1` (1970) is
therefore always expired.

**`deliverEgg(userId, data, codeId, rarity)`** (`:241`)

Returns `{ ok, queued, failed }`.

1. All of `slotServiceRef`, `eggServiceRef`, `playerServiceRef` must be
   set, else `{ failed = true }`.
2. `slotServiceRef.GetFreeSlot(userId)` → must be a table with a string
   `id`, else `{ queued = true }` (no free slot right now).
3. `slotServiceRef.ReserveSlot(slot.id)` must return exactly `true`, else
   `{ queued = true }`.
4. Snapshot the existing `data.LuckyBlocks` ids into `before`.
5. `playerServiceRef.AddEgg(userId, slot.id, rarity, nil, nil)` must return
   `true`. On failure: release the slot, `{ queued = true }`.
6. **Find the new record by diffing ids** and matching `rec.SlotId ==
   slot.id`. `AddEgg` returns a bool, not the record, so the diff is the
   only way to learn the minted id. If no record is found: release the slot,
   `{ queued = true }`.
7. `eggServiceRef.SpawnFromPersistence(userId, record, slot)` must return
   `{ success = true }`. On failure: `playerServiceRef.RemoveEgg(userId,
   record.Id)`, release the slot, `{ queued = true }` — a retry is always
   safe.

`deliverAnimal` (`:346`) is the same shape with `AddAnimal(userId, slot.id,
defId, nil, { Level = level or 1, Trait = trait })` and
`animalServiceRef.SpawnFromPersistence`.

**`TryDeliverPending(userId)`** (`:422`)

- Returns `false` if `userId` is not a number, or if `delivering[userId]` is
  set (reentrancy guard).
- Sets `delivering[userId] = true`, and **always** clears it at the end.
- Iterates `data.PendingCodeRewards`. Malformed entries are dropped with a
  log; well-formed but still-slotless entries are **kept**.
- On delivery, notifies `Codes_PendingDelivered` with
  `{ RewardText = ' +1 Rare Egg, +Chicken' }`.
- Returns `true` if at least one reward landed.

**`QueuePendingReward(data, entry)`** (`:511`) — appends to
`data.PendingCodeRewards` (creating the table if absent). No validation; the
caller constructs a well-formed entry.

**`sanitizePendingEntry(entry)`** (`:152`) — the pure shape check:

- `Kind == 'Egg'` → `Rarity` must be a string AND `EggConfig.Price[Rarity]`
  must exist; `Code` must be a non-empty string.
- `Kind == 'Animal'` → `DefId` must exist in `AnimalConfig.Get`; `Trait`, if
  present, must be a string; `Level`, if present, must be a number `>= 1`;
  `Code` must be a non-empty string.
- Anything else → `nil` (dropped).

**Slot availability is NOT checked here.** An entry that cannot be delivered
*now* is well-formed and must be **kept**, not dropped.

**`NormalizePlayer(userId)`** (`:198`) — the load-time + join-time repair.
- Ensures `data.RedeemedCodes` and `data.PendingCodeRewards` are tables.
- Drops malformed pending entries (with a log), keeps the rest verbatim.

### 2.4 `DailyRewardsService`

**State:** `locks` (per-player), `_skipAccess` (per-player session
entitlement), `lastBroadcastWeekId` (rollover push marker), `started`.

**`WEEK_COMPLETE_DAY = 8`** (`:93`) — the internal sentinel. Never a reward
day, never displayed as one.

**`sliceOf(data)`** (`:154`) — lazy-heals the profile slice:
`{ WeekId = '', Day = 1, LastClaimAt = 0 }`. Repairs a wrong-typed
`WeekId`, a non-integer or `< 1` `Day` (→ 1), a `Day > 8` (→ 8), and a
negative `LastClaimAt` (→ 0). **It never deletes progress.**

**`ensureWeek(slice, weekId)`** (`:190`) — if `slice.WeekId ~= weekId`:
reset `WeekId`, `Day = 1`, `LastClaimAt = 0`. Returns `true` when it
reset. Progress never crosses weeks; a new week starts at Day 1 **available
but never auto-granted**.

**`computeStatus(slice, now)`** (`:204`) — pure eligibility.

- `day = clamp(floor(slice.Day), 1, 8)`.
- If `day > DayCount()` (7) → `{ canClaim = false, nextAt = 0 }` — the week
  is done until the next global week, no matter how much time passes.
- If `LastClaimAt <= 0` → claimable now.
- `elapsed = now - LastClaimAt`. If `elapsed < 0` (clock moved backwards) →
  **fail closed**: `{ canClaim = false, nextAt = last + interval }`.
- If `elapsed >= ClaimInterval` → claimable.
- Otherwise → locked until `last + interval`.

**`dayState(day, status)`** (`:265`) — exactly one of three strings:

```text
Claimable  if status.canClaim and status.claimDay == day
Claimed    if day < status.day
Locked     otherwise
```

**The `Claimed` rule is `d < slice.Day`, not `d <= slice.Day`.** Deriving
"claimed" from `day <= currentDay` was the *Day-2-auto-Claimed bug*. The
current day is never `Claimed` merely by being current.

**`checkInvariants(days, slice, status, context)`** (`:290`) — a development
audit. It warns loudly if:
- a day is `Claimable` without matching eligibility,
- a day is `Claimed` without `d < slice.Day`,
- a day has an unknown state,
- **more than one day is `Claimable`**.

Violations are logged but the state is still returned (fail-open display,
fail-closed grants — `ClaimInner` revalidates).

**`GetSnapshot(userId, nowOverride?)`** (`:373`)

- `nil` if the profile is missing or `week.PoolId == ''`.
- Calls `ensureWeek` as a side effect (a fresh course on a new global week,
  never a grant).
- Returns the full snapshot listed in §2.1.

**`Claim(player, clickedDay)`** (`:438`)

- Mutex on `locks[userId]`. A concurrent request returns `busy` with the
  `General_Cooldown` notification.
- `pcall(ClaimInner)`. On error → `internal`.
- On success → `FunnelService:LogStep(player, 'Rewards',
  'DailyRewardClaimed', { day = clickedDay })`.
- Pushes the result once.

**`ClaimInner(player, userId, clickedDay)`** (`:472`)

1. Systems + profile present, else `no-systems`.
2. `week.PoolId ~= ''`, else `invalid-config`.
3. `ensureWeek` + `computeStatus`.
4. **Clicked-day validation:**
   - If `clicked` is a number in `1..DayCount()` and `clicked < slice.Day`
     → `already-claimed` (notification `Daily_AlreadyClaimed`).
   - If not `status.canClaim` → `not-ready` (`Daily_NotReady`).
   - If `clicked ~= nil and clicked ~= claimDay` → `not-ready`.
   - If `claimDay` is out of `1..DayCount()` → `not-ready`.
5. The pool's day entry must exist and pass `CodesConfig.ValidateRewards`,
   else `invalid-config`.
6. `commitDayRewards(...)`.

**`commitDayRewards(player, userId, data, slice, week, claimDay, entry, now, quiet)`** (`:545`)

The shared day grant, used by both `Claim` and `ClaimAll`.

- Tools → cash → slot rewards, then `slice.Day = claimDay + 1` and
  `slice.LastClaimAt = now`.
- `quiet` suppresses the per-day toast and the state push (ClaimAll
  composes one summary instead). **The streak still advances per day**,
  exactly as single claims do.
- Builds `rewardText` as `' ' .. table.concat(parts, ', ')`, with
  `' (queued: free a base slot!)'` appended when anything was queued.
- The result carries the **complete fresh state**: `{ Success = true, Day =
  claimDay, RewardText = rewardText, State = snapshot }`.
- **Eligibility-edge push:** if `slice.Day <= DayCount()` and not quiet, a
  single-shot `task.delay(ClaimInterval + 1)` pushes a fresh snapshot so the
  topbar alert turns ON without reopening the panel. No loop, no polling, no
  Heartbeat.
- Calls `maybeBroadcastWeek(week.WeekId)`.

**`ClaimAll(player)`** (`:739`) — the skip-all.

- **Requires `_skipAccess[userId] == true`.** Without it → `{ Success =
  false, Reason = 'no-access' }` with the `Shop_SkipRequired` notification.
- Mutex on `locks[userId]`.
- `ClaimAllInner` (`:775`) iterates `day = slice.Day .. DayCount`:
  - A day whose entry is missing or fails `ValidateRewards` → **stop** the
    pass (`invalid-config`).
  - A day whose commit fails → **stop** the pass.
  - Days that already succeeded **stay granted**, so a retry continues
    instead of duplicating. Idempotent.
- Returns `{ Success = true, ClaimedDays, Complete, RewardText, State }`.
  A fully-claimed week succeeds immediately with zero grants.
- Summary text: `'Skipped %d day(s). Day 1: ... | Day 2: ...'`.

**`maybeBroadcastWeek(weekId)`** (`:397`) — on a new global week, push a
**per-player** snapshot to every in-game player. It is a loop, not a shared
payload, because per-player progress differs. No timers — piggybacked on
reward traffic. `lastBroadcastWeekId` prevents a repeat.

**`GrantSkipAccess(player)`** (`:910`) — sets `_skipAccess[userId] = true`.
Idempotent, session-only, cleared on leave. Accepts anything with a numeric
`UserId` (real players and table fakes alike). **Only the Shop receipt path
may call it.**

### 2.5 `PlaytimeRewardsService`

**State:** `sessions` (`{[userId]: {start, poolId, dayId, token}}`),
`sessionToken` (a monotonically increasing counter), `locks`, `_skipAccess`,
`started`.

**Session model**

```lua
sessions[userId] = {
    start  = os.clock(),   -- monotonic
    poolId = '<PoolId>',
    dayId  = '<D%06d>',
    token  = <sessionToken>,
}
```

`sessionPlaytime(session) = max(0, os.clock() - session.start)`.

**Raw playtime is never persisted and never Heartbeat-ticked into the
profile.** It derives from the session timestamp on demand. AFK counts —
there is no activity tracking by design.

**`resolveSession(userId, data)`** (`:216`) — the pool lifecycle.

1. An existing session is returned as-is.
2. `today = PlaytimeRewardsDay.Current()`. If `today.PoolId == ''` → `nil`.
3. **Completed course** (`persisted.Completed == true`): pick
   `randomPoolExcluding(persisted.PoolId)` — a *personal* pool, excluding
   the completed one when alternatives exist. Reset `persisted.DayId`,
   `persisted.PoolId`, `persisted.Claimed = {}`, `persisted.Completed =
   false`. **This is the one documented exception to "everyone gets the
   same pool"** — it never touches other players' live sessions.
4. **Resume** (`persisted.DayId == today.DayId` and the pool is still
   valid): keep the pool and the claimed set. Playtime restarts at 0.
5. Otherwise (fresh profile, new IST day, or config drift): today's global
   pool, `Claimed = {}`, `Completed = false`.
6. Mint a new `sessionToken`, store the session, and **arm the threshold
   pushes**: for each unclaimed milestone, a single-shot
   `task.delay(RequiredPlaytime + 1)` that pushes a fresh snapshot — but only
   if the session token, pool id, and day id still match. Stale sessions
   never push.

**`milestoneState(claimed, playtime, required)`** (`:340`)

```text
Claimed     if claimed
Claimable   if playtime >= required
Locked      otherwise
```

Multiple milestones may be `Claimable` at once. Each is claimed
individually.

**`GetSnapshot(userId)`** (`:360`)

- Resolves the session lazily, so any order of join/request works.
- `nil` if the profile, the session, or the pool is unavailable.
- `Playtime = math.floor(playtime)`.
- `Version = math.floor(os.clock() * 1000)` — the client uses it to order
  out-of-order state pushes.
- `Completed` is true when every milestone is claimed.

**`Claim(player, index)`** (`:485`) and **`ClaimInner`** (`:519`)

- Mutex on `locks[userId]` → `busy`.
- `index` must be an integer in `1..#pool.Milestones`, else `not-ready`
  (`Playtime_NotReady`).
- The milestone's rewards must pass `CodesConfig.ValidateRewards`, else
  `invalid-config`.
- An already-claimed index → `already-claimed` (`Playtime_AlreadyClaimed`).
- `playtime < milestone.RequiredPlaytime` → `not-ready`.
- Tools present but `gearShopServiceRef` unset → `no-systems`.

**`commitMilestone(...)`** (`:578`) — the shared grant. Tools → cash →
slots, then `persisted.Claimed[index] = true`. If that makes the count
reach `#pool.Milestones`, `persisted.Completed = true`.

**Claiming never advances playtime and never touches siblings.**

The pending label is `'PLAYTIME_<PoolId>_M<index>'`.

**`ClaimAll(player)`** (`:742`) — same Robux gate as Daily
(`_skipAccess`), same stop-on-failure semantics, same idempotency.
Returns `{ Success = true, ClaimedCount, RewardText, State }`.

**`ForgetPlayer(userId)`** — **defined twice** (`:477` and `:723`). The
later one wins at runtime; it clears `sessions`, `locks`, **and**
`_skipAccess`. The earlier one is dead code and did not clear the
entitlement. A copy-paste hazard.

### 2.6 `PlaytimeRewardsDay`

**`IST_OFFSET_SECONDS = PlaytimeRewardsConfig.Settings.DayBoundaryOffsetSeconds`** (`:43`)
— the config is the single source of truth (it used to be a hardcoded
`19800` here).

**`DayIndexAt(now) = math.floor((now + IST_OFFSET_SECONDS) / 86400)`** (`:65`)
— pure arithmetic on server time. Never the client clock, never
server-local midnight.

**`DayId = ('D%06d'):format(dayIndex)`** (`:69`).

**`loadOrSelectGlobal(dayId)`** (`:151`) — the DataStore path.
`UpdateAsync('CurrentDay', function(current) ... end)`:

- If `current.DayId == dayId` and `current.PoolId` is still a valid pool
  → return `current` unchanged (the day's pick is stable).
- Otherwise pick `randomPoolId(prev)` and commit
  `{ DayId, PoolId, PreviousPoolId = prev, SetAt = os.time() }`.

`UpdateAsync` is **atomic per key**: servers reaching a new day
simultaneously serialize; the loser re-runs against the winner's committed
value and keeps it. Exactly one pool wins.

**`Current(nowOverride?)`** (`:187`)

- Cached per `dayIndex`, and the cache is only used when the cached pool id
  is still valid.
- `Source` is `'global'` (DataStore), `'local-fallback'` (deterministic
  hash), or `'misconfigured'` (no valid pool).
- The fallback is `deterministicPoolId(dayId, dayIdOf(dayIndex - 1))` — a
  hash of the `DayId` over the catalog, skipping the previous day's hash
  pick when alternatives exist. It is **deterministic**, so all servers
  agree even with the store down.
- Never throws.

### 2.7 `DailyRewardsWeek`

The global weekly pool selector — the direct sibling of
`PlaytimeRewardsDay`, and the **required dependency** of
`DailyRewardsService`. The service reaches it with
`require(script.Parent.DailyRewardsWeek)` at the top of the file (not
deferred), so the file must be a **direct child** of
`ServerScriptService.Daily/`.

Source: `Source/ServerScriptService/Daily/DailyRewardsWeek.lua` (235
lines). It is byte-identical to the source game's
`src/ServerScriptService/Daily/DailyRewardsWeek.lua` (md5
`c1493292e580a6b8e0b5c27c51bc6b12`).

**Module state:**

```lua
local cache: { weekIndex: number, weekId: string, poolId: string, source: string } =
    { weekIndex = -1, weekId = '', poolId = '', source = '' }
local storeHandle: DataStore? = nil
local storeFailed = false
```

`cache.weekIndex = -1` is the sentinel that guarantees the first call
misses.

**`Current(nowOverride?)`** — the whole algorithm:

1. `now = nowOverride` if it is a number, else `os.time()`. **Server
   time only** — the client clock is never consulted.
2. `weekIndex = math.floor(now / 604800)`.
3. **Cache hit?** `cache.weekIndex == weekIndex` **and**
   `validPoolId(cache.poolId)`. If yes, return the cached triple
   immediately. This is the O(1) path — no DataStore traffic at all
   within a week.
4. `weekId = ('W%06d'):format(weekIndex)`.
5. `committed = loadOrSelectGlobal(weekId)`.
   - If non-`nil` → `poolId = committed.PoolId`, `source = 'global'`,
     log `'global pool active'`.
   - If `nil` → `poolId = deterministicPoolId(weekId, weekIdOf(weekIndex - 1))`,
     `source = 'local-fallback'`, log
     `'global store unreachable, deterministic fallback'`.
6. **Misconfigured guard:** if `poolId == nil` or
   `not validPoolId(poolId)` → cache the miss *for the whole week*
   (`cache = { weekIndex, weekId, poolId = '', source = 'misconfigured' }`),
   `Debug.Warn('DailyRewardsWeek', 'no valid weekly pool for %s (check DailyRewardsConfig)')`,
   and return `{ WeekId = weekId, PoolId = '', Source = 'misconfigured' }`.
   Caching the miss is deliberate: it means the warning fires **once per
   week, not once per request**.
7. Cache the hit and return `{ WeekId, PoolId, Source }`.

**Note the cache-hit condition includes `validPoolId(cache.poolId)`.**
If the config is edited at runtime to remove the cached pool, the cache
is bypassed and the module re-resolves.

**`loadOrSelectGlobal(weekId)`** (`:~140`) — the atomic part.

```lua
store:UpdateAsync(DATASTORE_KEY, function(current)
    if type(current) == 'table' and current.WeekId == weekId and validPoolId(current.PoolId) then
        return current                    -- already committed for this week
    end
    local prev = (type(current) == 'table' and type(current.PoolId) == 'string') and current.PoolId or nil
    local poolId = randomPoolId(prev)
    if poolId == nil then
        return current                    -- misconfigured catalog: keep the old value
    end
    return { WeekId = weekId, PoolId = poolId, PreviousPoolId = prev, SetAt = os.time() }
end)
```

Three properties make this correct:

- **The transform is pure and yields nothing.** `randomPoolId` uses
  `math.random` and `os.time()` only. Roblox forbids yielding inside an
  `UpdateAsync` transform, and a pure transform is what lets the loser
  of a race simply re-run.
- **The atomicity is per key.** `UpdateAsync` on a single key serializes
  across the whole fleet. Two servers crossing the week boundary at the
  same moment both run their transform; the second one sees the first
  one's committed value, whose `WeekId` now equals the new week, so it
  returns `current` unchanged. **Exactly one pool wins.**
- **The old value is preserved on failure.** If the catalog has no valid
  pool, `randomPoolId` returns `nil` and the transform returns `current`
  unchanged rather than writing garbage.

The whole `UpdateAsync` is `pcall`-wrapped. If it throws (network
failure, throttling, Studio without API access) the function returns
`nil` and the caller takes the fallback path.

The **return** is re-validated after the `pcall`:
`if ok and type(result) == 'table' and result.WeekId == weekId and validPoolId(result.PoolId)`.
So a store that returns something unexpected is treated as unreachable.

**`randomPoolId(excludeId)`** — the global pick.

- 0 pools → `nil`.
- 1 pool → that pool (a single-pool catalog trivially repeats).
- Otherwise: build `candidates` = all ids except `excludeId`; if that
  ends up empty, fall back to all ids; return
  `candidates[math.random(#candidates)]`.

`excludeId` is the **previous week's** pool (the stored
`PreviousPoolId` at the moment of selection — note: the value stored in
the record is the pool from the week *before* the one being written).
This is what gives the "never two identical weeks in a row" promise.

**`math.random` is not seeded.** The selection is not reproducible from
the week id. It does not need to be — only one server's roll survives.

**`deterministicPoolId(weekId, prevWeekId)`** — the fallback pick.

```lua
local pick = ids[(hashWeek(weekId) % #ids) + 1]
if prevWeekId ~= nil then
    local prevPick = ids[(hashWeek(prevWeekId) % #ids) + 1]
    if pick == prevPick then
        pick = ids[((hashWeek(weekId) + 1) % #ids) + 1]
    end
end
```

`hashWeek` is a 33-multiplier rolling hash mod 1000003 over the bytes of
the week id.

The avoid-repeat logic here is **weaker** than the DataStore path's: it
avoids repeating the *previous week's hash pick*, which is not
necessarily the pool that was actually served last week (the DataStore
path may have committed a different, randomly-chosen pool). The source
file's own header calls this out as a documented limitation.

**`getStore()`**

```lua
if storeHandle ~= nil then return storeHandle end
if storeFailed then return nil end
local ok, store = pcall(function() return DataStoreService:GetDataStore(DATASTORE_NAME) end)
if ok and store ~= nil then storeHandle = store; return store end
storeFailed = true
return nil
```

`storeFailed` is a **permanent latch**. There is no retry, no backoff,
no timer. Once the handle acquisition fails, the module is in fallback
mode for the rest of the server's life.

**`validPoolId(poolId)`**

`DailyRewardsConfig.FindPool(DailyRewardsConfig.WeeklyPools, poolId) ~= nil`
— i.e. the id must exist in the configured catalog. A pool that was
removed from the config is treated as invalid, which means a stale
DataStore value with a removed pool triggers a re-selection.

**The week anchor.** `WeekId` is an epoch-anchored global week index:
`('W%06d'):format(math.floor(os.time() / 604800))`. Because the anchor
is a fixed divisor of the Unix epoch, the boundaries fall on **Thursday
00:00 UTC**. The anchor never moves, so every server trivially agrees on
"this week" without any coordination. This is a deliberate, non-obvious
choice: a Thursday boundary means the "week" does not align with the
calendar week most players think of.

**The avoid-repeat promise.** With more than one pool configured, the
newly selected pool never equals the stored `PreviousPoolId`. **Only
back-to-back repeats are excluded** — week N+1 may reuse week N-1's pool.
A single-pool catalog trivially repeats. The fallback path can only do
**best-effort** here: it knows the hash chain (it can compute what last
week's hash pick was) but not a stored `PreviousPoolId`, so the no-repeat
guarantee is weaker without the DataStore.

**Consumption.** `DailyRewardsService` calls `Current()` per request (an
O(1) integer compare on a cache hit) and broadcasts fresh **per-player**
snapshots when the week rolls over. It uses `week.WeekId` to align the
player's per-player streak slice (`ensureWeek`), and `week.PoolId` to
look up the 7-day course in
`DailyRewardsConfig.FindPool(DailyRewardsConfig.WeeklyPools, week.PoolId)`.
The `WeekId` is stored on the profile as `DailyRewards.WeekId`. When it
does not match the current `week.WeekId`, the player's streak resets to
day 1 — the progress never crosses a week boundary.

---

## 3. Public API surface

### `ReplicatedStorage.Config.Economy.Rewards`

```lua
-- Codes
Codes.NormalizeCode(input: any): string?
Codes.GetAll(): { CodeDef }
Codes.FindById(id: string): CodeDef?
Codes.ValidateRewards(rewards: any): { string }
Codes.ValidateList(codes: any): { string }
Codes.ValidateLive(): { string }
Codes.Validate(): { string }

-- Daily
Daily.Settings: DailySettings          -- { ClaimInterval }
Daily.WeeklyPools: { DailyPoolDef }
Daily.DayCount(): number
Daily.FindPool(pools: any, poolId: string): DailyPoolDef?
Daily.ValidateList(pools: any, settings: any): { string }
Daily.ValidateLive(): { string }
Daily.Validate(): { string }

-- Playtime
Playtime.Settings: PlaytimeSettings    -- { SessionResetsOnLeave, DailyResetTimezone,
                                        --   DailyResetHour, DailyResetMinute,
                                        --   SkipAllEnabled, DayBoundaryOffsetSeconds }
Playtime.Pools: { PlaytimePoolDef }
Playtime.MilestoneCount(): number
Playtime.FindPool(pools: any, poolId: string): PlaytimePoolDef?
Playtime.ValidateList(pools: any, settings: any): { string }
Playtime.ValidateLive(): { string }
Playtime.Validate(): { string }
```

### `ServerScriptService.Codes.CodesService`

```lua
CodesService.SetPlayerService(svc: any): ()
CodesService.SetEconomyService(svc: any): ()
CodesService.SetSlotService(svc: any): ()
CodesService.SetEggService(svc: any): ()
CodesService.SetAnimalService(svc: any): ()
CodesService.SetGearShopService(svc: any): ()
CodesService.NormalizePlayer(userId: number): ()
CodesService.TryDeliverPending(userId: number): boolean
CodesService.DeliverEggReward(userId: number, data: any, codeLabel: string, rarity: string): { ok: boolean, queued: boolean, failed: boolean }
CodesService.DeliverAnimalReward(userId: number, data: any, codeLabel: string, defId: string, trait: string?, level: number?): { ok: boolean, queued: boolean, failed: boolean }
CodesService.QueuePendingReward(data: any, entry: { [string]: any }): ()
CodesService.Redeem(player: Player, codeText: any): { [string]: any }
CodesService.RedeemInner(player: Player, userId: number, norm: string): { [string]: any }
CodesService.OnPlayerReady(player: Player): ()
CodesService.ForgetPlayer(userId: number): ()
CodesService.Init(): ()
CodesService._TestReset(): ()
```

### `ServerScriptService.Daily.DailyRewardsService`

```lua
DailyRewardsService.SetPlayerService(svc: any): ()
DailyRewardsService.SetEconomyService(svc: any): ()
DailyRewardsService.SetGearShopService(svc: any): ()
DailyRewardsService.SetCodesService(svc: any): ()
DailyRewardsService.GetSnapshot(userId: number, nowOverride: number?): { [string]: any }?
DailyRewardsService.PushState(player: Player): ()
DailyRewardsService.Claim(player: Player, clickedDay: any): { [string]: any }
DailyRewardsService.ClaimInner(player: Player, userId: number, clickedDay: any): { [string]: any }
DailyRewardsService.ClaimAll(player: Player): { [string]: any }
DailyRewardsService.ClaimAllInner(player: Player, userId: number): { [string]: any }
DailyRewardsService.ForgetPlayer(userId: number): ()
DailyRewardsService.Init(): ()
DailyRewardsService._TestReset(): ()
DailyRewardsService.GrantSkipAccess(player: any): boolean
```

### `ServerScriptService.Playtime.PlaytimeRewardsService`

```lua
PlaytimeRewardsService.SetPlayerService(svc: any): ()
PlaytimeRewardsService.SetEconomyService(svc: any): ()
PlaytimeRewardsService.SetGearShopService(svc: any): ()
PlaytimeRewardsService.SetCodesService(svc: any): ()
PlaytimeRewardsService.GetSnapshot(userId: number): { [string]: any }?
PlaytimeRewardsService.PushState(player: Player): ()
PlaytimeRewardsService.PushStateById(userId: number): ()
PlaytimeRewardsService.OnPlayerReady(player: Player): ()
PlaytimeRewardsService.Claim(player: Player, index: any): { [string]: any }
PlaytimeRewardsService.ClaimInner(player: Player, userId: number, index: any): { [string]: any }
PlaytimeRewardsService.ClaimAll(player: Player): { [string]: any }
PlaytimeRewardsService.ClaimAllInner(player: Player, userId: number): { [string]: any }
PlaytimeRewardsService.ForgetPlayer(userId: number): ()
PlaytimeRewardsService.Init(): ()
PlaytimeRewardsService._TestReset(): ()
PlaytimeRewardsService.GrantSkipAccess(player: any): boolean
```

### `ServerScriptService.Playtime.PlaytimeRewardsDay`

```lua
PlaytimeRewardsDay.DayIndexAt(now: number): number
PlaytimeRewardsDay.Current(nowOverride: number?): { DayId: string, PoolId: string, Source: string }
PlaytimeRewardsDay._TestReset(): ()
```

### `ServerScriptService.Daily.DailyRewardsWeek`

```lua
DailyRewardsWeek.Current(nowOverride: number?): { WeekId: string, PoolId: string, Source: string }
DailyRewardsWeek._TestReset(): ()
```

There is **no** `Init()`, no `Start()`, no setter, and no `Set*Service`.

---

## 4. Invariants the code enforces

1. **The client never supplies a reward, an amount, a day, a pool, or a
   playtime.** It supplies intent only. The server re-resolves everything.
2. **The commit order is tools → cash → slots → mark.** Nothing is marked
   until everything above has landed or been safely persisted as pending.
3. **Tools are idempotent.** A retry cannot duplicate a tool.
4. **Cash cannot fail after validation.** `AddMoney` with
   `ApplyMultiplier = false` and reason `'CodeReward'`.
5. **Slot rewards never fail destructively.** They land in a reserved slot
   or become pending entries. Pending is not loss.
6. **A pending entry that cannot be delivered now is kept, not dropped.**
   Only *malformed* entries are dropped.
7. **A pending entry is delivered exactly once** — the delivery loop
   rebuilds the remaining list and replaces the profile array.
8. **The daily `Claimed` rule is `d < slice.Day`.** The current day is
   never `Claimed` by virtue of being current.
9. **A new global week resets the daily slice to Day 1, available but never
   auto-granted.** Progress never crosses weeks.
10. **A backwards clock fails closed.** The day stays locked until the
    original anchor passes again.
11. **Day 8 is a sentinel, never a reward day.**
12. **At most one day is `Claimable` at a time** (audited by
    `checkInvariants`).
13. **The playtime pool never changes mid-session**, even across IST
    midnight.
14. **Claiming a playtime milestone never advances playtime and never
    touches siblings.**
15. **Skip-all requires a prior `GrantSkipAccess`.** A bare `ClaimAll`
    remote is rejected with `no-access`.
16. **Skip-all is idempotent.** A failure part-way leaves the already-granted
    days granted; a retry continues.
17. **The global week/pool and the global day/pool are selected atomically
    (`UpdateAsync`),** so exactly one value wins across all servers.
18. **The playtime fallback is deterministic**, so servers agree even when
    the DataStore is unreachable.
19. **The weekly pool is a function of the week, not of the server.** Every
    server that can reach the DataStore returns the same `PoolId` for the
    same `WeekId`.
20. **The weekly `UpdateAsync` transform is pure and non-yielding.** This
    is what makes the no-split-brain guarantee work.
21. **A committed weekly value is reused, not re-rolled.** The transform
    returns `current` unchanged when `current.WeekId == weekId` and the
    pool is still valid.
22. **The stored weekly `PoolId` is always re-validated against the config**
    before it is trusted — on read (`validPoolId`) and after the write
    (`validPoolId(result.PoolId)`).
23. **The old weekly value is never destroyed by a misconfiguration.** The
    transform returns `current` when it cannot pick a valid pool.
24. **The weekly avoid-repeat promise excludes only back-to-back repeats.**
    Week N+1 may reuse week N-1's pool.
25. **A single-pool weekly catalog trivially repeats** — `randomPoolId`
    returns that pool and the exclude logic is a no-op.
26. **The weekly misconfiguration warning fires once per week**, because
    the miss is cached with the week's `weekIndex`.
27. **The weekly `Source` is informational.** Nothing in the game branches
    on it.

---

## 5. Failure and edge-case behaviour

| Situation | Behaviour |
|---|---|
| `Redeem` with a non-string code | `unknown-code` / `Codes_InvalidCode` |
| `Redeem` with a code longer than 64 chars | rejected at the remote handler |
| `Redeem` with an empty/whitespace code | `NormalizeCode` returns `nil` → `unknown-code` |
| `Redeem` with a valid but unknown code | `unknown-code` |
| `Redeem` with a disabled code | `disabled` / `Codes_CodeDisabled` |
| `Redeem` with an expired code | `expired` / `Codes_CodeExpired` |
| `Redeem` twice with the same code | `already-redeemed` / `Codes_AlreadyRedeemed` |
| `Redeem` when the global cap is hit | `disabled` / `Codes_CodeDisabled` (deliberate: the cap is best-effort) |
| `Redeem` with a malformed reward config | `invalid-config` / `General_Generic` |
| `Redeem` when a required service is unwired | `no-systems` / `General_Generic` |
| Two concurrent `Redeem`s for the same code | the second gets `busy` / `General_Cooldown` |
| `Redeem` with no free base slot | the reward is **queued**; the code is still marked redeemed; the toast says `(queued: free a base slot!)` |
| The egg spawn fails after the record was written | the record is removed, the slot is released, the reward is queued |
| `TryDeliverPending` with a reentrant call | returns `false` immediately |
| `TryDeliverPending` with malformed entries | they are dropped and logged; the rest are attempted |
| `TryDeliverPending` for a player who left | returns `false` (no `Player` found) |
| `RedeemInner` throws | caught by `Redeem` → `internal` / `General_Generic` |
| The global count exceeds `MaxGlobalRedemptions` | the redemption is refused, but the **counter is still incremented** — it is a best-effort cap, not a hard quota |
| The daily `Claim` for a day already claimed | `already-claimed` / `Daily_AlreadyClaimed` |
| The daily `Claim` before the interval elapses | `not-ready` / `Daily_NotReady` |
| The daily `Claim` for the wrong (but unlocked) day | `not-ready` / `Daily_NotReady` |
| The daily `Claim` when the clock moved backwards | `not-ready` (fail closed) |
| The daily `Claim` on a fully-claimed week | `not-ready` (day 8 is never claimable) |
| The daily `ClaimAll` without an entitlement | `no-access` / `Shop_SkipRequired` |
| The daily `ClaimAll` on a fully-claimed week | `Success = true`, `ClaimedDays = 0` |
| The daily `ClaimAll` hits a bad config day | the pass **stops** at that day; earlier days stay granted |
| The daily snapshot for a missing profile | `nil` |
| The daily snapshot when the week pool is empty | `nil` |
| The playtime `Claim` for an out-of-range index | `not-ready` / `Playtime_NotReady` |
| The playtime `Claim` for an already-claimed milestone | `already-claimed` / `Playtime_AlreadyClaimed` |
| The playtime `Claim` before the threshold | `not-ready` / `Playtime_NotReady` |
| The playtime `ClaimAll` without an entitlement | `no-access` / `Shop_SkipRequired` |
| The playtime `ClaimAll` on a fully-claimed session | `Success = true`, `ClaimedCount = 0` |
| The player leaves mid-session | the session is discarded; rejoin starts at 0 but does not re-grant claimed milestones |
| IST midnight passes while online | the session pool **does not change**; the next join resolves anew |
| The DataStore is unreachable (`PlaytimeRewardsDay`) | `Source = 'local-fallback'`, a deterministic hash pick |
| No valid pool exists | `Source = 'misconfigured'`, `PoolId = ''`, a warning is logged |
| `GrantSkipAccess` with a non-numeric `UserId` | returns `false` |
| `GrantSkipAccess` called twice | idempotent — `true` both times |
| The weekly DataStore is unreachable (`DailyRewardsWeek`) | `Source = 'local-fallback'`, a deterministic hash pick; `storeFailed` latches permanently |
| The weekly store returns a non-table | the post-`pcall` re-validation rejects it → fallback |
| The weekly store returns a table for a different week | the transform re-selects and writes |
| The committed weekly pool was removed from the config | `validPoolId` fails → the transform re-selects |
| The weekly catalog has **zero** pools | `randomPoolId` → `nil` → the transform keeps `current` → `deterministicPoolId` → `nil` → misconfigured. `PoolId = ''`, `Source = 'misconfigured'`, one warning per week |
| The weekly catalog has exactly **one** pool | that pool is always selected, on both paths |
| The committed weekly `PoolId` equals the previous week's | `randomPoolId` excludes it, so a different pool is chosen (when >1 pool exists) |
| `Current(nowOverride)` with a non-number | `now = os.time()` — the override is ignored |
| `Current(nowOverride)` with a number | the week index is computed from it |
| The weekly `Debug` module missing | the `require` at the top of the file fails — the module does not load |
| The `Rewards` config missing / `Daily` nil | the `require` fails or `FindPool` errors — hard error at require time |

---

## 6. Gotchas that will bite you

1. **`script.Parent.DailyRewardsWeek` is a *sibling* require.**
   `DailyRewardsService` reaches the week selector through
   `script.Parent`, so `DailyRewardsWeek.lua` must be a **direct child**
   of the same folder as `DailyRewardsService.lua` — i.e.
   `ServerScriptService.Daily/`. You cannot move it elsewhere without
   editing the consumer's require. It now lives in this folder at
   `Source/ServerScriptService/Daily/DailyRewardsWeek.lua`; keep it there.
2. **`CodesService` is the shared delivery pipeline.** Daily and Playtime
   do **not** have their own egg/animal delivery — they call
   `CodesService.DeliverEggReward` / `DeliverAnimalReward` /
   `QueuePendingReward`. If you extract Codes without Daily/Playtime, or
   vice versa, you break the other.
3. **`slice.Day` is the NEXT claimable day, not the last claimed day.**
   After claiming day 1, `Day == 2`. This is the single most misread piece
   of state in the system, and it is why the `Claimed` rule is `d <
   slice.Day`.
4. **`Day = 8` is a sentinel.** It means "week complete", not "day 8".
5. **`ClaimAll` without `GrantSkipAccess` is a hard no-op** (`no-access`).
   The entitlement is **session-only** and is cleared by `ForgetPlayer` —
   a player who buys the skip and then leaves loses it.
6. **The skip-all entitlement is granted by the Shop receipt path only.**
   Never call `GrantSkipAccess` from a remote handler.
7. **`PlaytimeRewardsService.ForgetPlayer` is defined twice.** The second
   definition wins. If you edit the first one, nothing happens.
8. **`PlaytimeRewardsDay`'s DataStore name is a hardcoded literal**
   (`'p7_PlaytimeRewards_Daily_v1'`). Change it per game.
9. **`DayBoundaryOffsetSeconds` (19800) is pinned** by
   `ConfigValidator._checkInvariants` and by
   `ConfigArchitecture.spec.lua`. Changing it breaks the config spec unless
   you update both.
10. **`Playtime.Settings.DailyResetTimezone` is documentation, not
    arithmetic.** The arithmetic is `DayBoundaryOffsetSeconds`. They must
    agree, but nothing enforces that.
11. **`Playtime.Settings.SkipAllEnabled` does not gate anything.** The
    services gate on the entitlement. The flag is a validated boolean only.
12. **`Playtime.Settings.SessionResetsOnLeave` must be `true`** — the
    validator rejects `false`. It documents the rule; it is not a toggle.
13. **The `Day` / `Index` fields on the action payloads are UX/debug only.**
    The server recomputes them. Do not "optimize" by trusting them.
14. **The `Codes` catalog ids appear in server logs.** If a code must be
    secret, it is not secret.
15. **`AddEgg` / `AddAnimal` return a bool, not the record.** The delivery
    code finds the new record by **diffing ids** — if you change the
    id-minting scheme, the diff breaks and every slot-bound reward becomes
    "queued" forever.
16. **Tool rewards are session-only.** `EnsureGearTool` gives a `Tool`
    instance, not a persisted entitlement.
17. **The daily `ClaimInterval` is 24 h from the last claim**, not a
    calendar midnight. A player who claims at 23:00 waits 24 h.
18. **The daily `ClaimAll` summary is one toast**, and the per-day
    `quiet` path suppresses the per-day state push — but the streak still
    advances per day.
19. **The playtime course completes only when *every* milestone is
    claimed.** Claiming the last one sets `persisted.Completed = true`,
    which is what triggers the personal-pool selection on the next session.
20. **The playtime fallback is deterministic**, not random. That is
    deliberate — all servers must agree when the store is down.
21. **There is no `DailyRewardsService.OnPlayerReady`.** If you add one,
    remember the daily service pulls its state lazily and its slot-bound
    rewards ride the Codes pending queue.
22. **`CodesService` returns the result table *and* pushes it.** Call
    `Redeem` (which pushes) or `RedeemInner` (which does not) — never
    both, or the client sees two results.
23. **`computeStatus` has a duplicated `if day > DayCount()` check.**
    Harmless dead code, but do not "fix" it by changing the semantics.

**`DailyRewardsWeek` specific (24–35):**

24. **The week boundary is Thursday 00:00 UTC.** Not Monday, not the
    local midnight. `604800` seconds from the Unix epoch lands on a
    Thursday.

25. **`cache.weekIndex` is a sentinel of `-1`, and the misconfiguration
    path caches `poolId = ''`.** After a misconfiguration, every later
    call in that week returns `PoolId = ''` **without re-warning** and
    without retrying the DataStore. If you fix the config mid-week, the
    module stays broken until the week rolls over or `_TestReset()` is
    called. This is a real trap: fix the catalog in Studio and the
    feature stays dead.

26. **`validPoolId(cache.poolId)` is part of the cache-hit condition.**
    That is what makes trap #25 escapable *only* via a config change
    that makes the pool valid again — which it does not, because the
    cached pool is `''`.

27. **`storeFailed` is a permanent latch.** Enabling API access in Studio
    mid-session does not recover. Restart the server.

28. **`Debug.Warn` uses the wrong tag.** Line 222 passes
    `'DailyRewardsWeek'` as the tag where every other call in the file
    uses `'DRW'`. With a non-empty `Debug.Tags` whitelist, the
    misconfiguration warning is filtered out. Add `DailyRewardsWeek` to
    the whitelist, or fix the call.

29. **The `Source` value `'local-fallback'` is not a degraded mode you
    can detect from the client.** It is only in the server log. If the
    global store is down for a week, players silently get the hash
    pick — and if the store comes back mid-week, the **committed** value
    (a random pool) replaces the fallback for the rest of that week.
    That is a visible content flip mid-week.

30. **The selection uses unseeded `math.random`.** You cannot
    precompute the pool for a given week. If you need a *scheduled* or
    *announced* rotation, you must replace the selection with something
    deterministic and global (e.g. a hash of the week id) — and accept
    that the DataStore then only stores it rather than choosing it.

31. **`SetAt` records `os.time()` at selection time**, which is the
    moment the *first* server crossed the boundary — not the boundary
    itself. Do not use it as "the week started at" in analytics.

32. **The `PreviousPoolId` written into the record is the pool of the
    week *before* the one being written.** On the very first write it
    is `nil` (there was no previous value). Read it as "the pool we are
    replacing".

33. **`_TestReset` also resets `storeFailed`,** so a spec can retry the
    store after a failure. But `DailyRewardsService._TestReset()` calls
    `DailyRewardsWeek._TestReset()` for you — resetting the daily
    service also resets this module.

34. **No `Config.lua` for the week selector.** `DATASTORE_NAME` and
    `SECONDS_PER_WEEK` are module-locals you must edit in the file.

35. **The `p7_` prefix in the DataStore name is the source game's
    identifier.** Change it, or you will share a DataStore with any
    other game using this code.

---

## 7. What to change to reuse it

| Change | Where |
|---|---|
| The code catalog | `Rewards.lua` → `CODES` |
| The daily pools | `Rewards.lua` → `DAILY_POOLS` |
| The playtime pools | `Rewards.lua` → `PLAYTIME_POOLS` |
| The daily interval | `Rewards.lua` → `Daily.Settings.ClaimInterval` |
| The days per pool | `Rewards.lua` → `DAYS_PER_POOL` (module-local, `:588`) — and the UI |
| The day boundary | `Rewards.lua` → `Playtime.Settings.DayBoundaryOffsetSeconds` (+ the timezone label) |
| The max slot units per code | `Rewards.lua` → `MAX_SLOT_UNITS_PER_CODE` (module-local, `:245`) |
| The economy reason string | `'CodeReward'` — hardcoded in all three services |
| The DataStore names | `PlaytimeRewardsDay.lua:45` and `DailyRewardsWeek.lua:49` (both in this system's `Source/` tree) |
| The notification ids | `Config/Presentation/Messages.lua` — the ids used are listed in §3 |
| The result/state payload shapes | the `Remotes.Names` registry + the `GetSnapshot` / `pushResult` functions |
| **The commit order** | do not change it. It is the transaction-safety contract. |
| **The pending-queue model** | do not replace it with a direct grant. Pending is not loss. |
| **The `d < slice.Day` rule** | do not change it. `d <= slice.Day` is the Day-2-auto-Claimed bug. |
| The global week/day selection | `DailyRewardsWeek` and `PlaytimeRewardsDay` — both use atomic `UpdateAsync` |
| The weekly DataStore name | `DailyRewardsWeek.lua:49` — `DATASTORE_NAME` (module-local) |
| The weekly rollover day | `DailyRewardsWeek.lua:48` — `SECONDS_PER_WEEK` is the anchor divisor; to move it to Monday 00:00 UTC edit `weekIndexAt` to `math.floor((now + 345600) / 604800)` (4 days). Changing the constant alone does **not** move the anchor. |
| Make the weekly rotation deterministic and pre-announceable | Replace `randomPoolId(prev)` inside the transform with `deterministicPoolId(weekId, prevWeekId)`. The DataStore then only *records* the choice. |
| Retry the weekly DataStore after a failure | Reset `storeFailed` in a retry path — but do it on a timer, and keep the fallback serving meanwhile. |
| Fix the weekly warning tag | Change `DailyRewardsWeek.lua:222` to `Debug.Warn('DRW', ...)`. |
| Recover from a weekly misconfiguration without waiting for the week to roll | Call `DailyRewardsWeek._TestReset()` after fixing the catalog. |
