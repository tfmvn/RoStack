# CodesAndRewards

Three reward systems that share **one** reward shape, **one** config module,
and **one** delivery pipeline:

- **Codes** (`CodesService`) — redeem codes from a server-authoritative
  catalog.
- **Daily** (`DailyRewardsService`) — a 7-day streak course, one pool per
  **global week**.
- **Playtime** (`PlaytimeRewardsService`) — a 6-milestone course, one pool
  per **session** (and per global IST day by default).

Plus the shared config module `ReplicatedStorage/Config/Economy/Rewards.lua`,
which owns the code catalog and both reward matrices, plus the two **global
pool selectors** that back the Daily and Playtime systems:

- **`DailyRewardsWeek`** — the global weekly pool selector (one pool per
  global week, identical on every server and every player).
- **`PlaytimeRewardsDay`** — the global IST-day pool selector.

**Portability:** Grade **A — portable core** (the whole
validate → grant → commit → persist pipeline, the pending-queue
transaction-safety model, the per-player mutex, the server-authoritative
intent-only protocol) + Grade **B — game-specific adapter** (the actual
codes, the reward contents, the pool ids, the 7-day/6-milestone shapes, the
`IST` day boundary, the `'CodeReward'` economy reason, the `p7_` DataStore
name). Grade **C** in that `PlaytimeRewardsDay` and `DailyRewardsWeek` talk
to `DataStoreService`.

**Source game:** Brainrot Arena (`p-7`).

> **Note on `DailyRewardsWeek`:** this system requires
> `ServerScriptService.Daily.DailyRewardsWeek`, and it **is** present in
> this folder at
> `Source/ServerScriptService/Daily/DailyRewardsWeek.lua` — byte-identical
> to the source game's copy. It is a **required, in-system dependency** of
> `DailyRewardsService` (which reaches it through
> `require(script.Parent.DailyRewardsWeek)`), so the file must stay a
> **direct child** of `ServerScriptService/Daily/`. See *What It Does*,
> *Entry Points* and *Known Limitations* below.

---

## What It Does

### The shared idea

All three systems follow the same contract:

1. The client sends **intent only** — a string code, or a "claim" action.
   Never an amount, never a reward, never a day index that is trusted.
2. The server **re-resolves** everything from the config: what the reward
   is, whether the player is eligible, what the day/pool/milestone is.
3. The grant happens through the **same canonical systems**:
   `EconomyService.AddMoney`, `GearShopService.EnsureGearTool`,
   `CodesService.DeliverEggReward` / `DeliverAnimalReward`.
4. The state advance happens **last**, and only if every step committed.

The **transaction-safety order** is identical in all three:

```text
tools  ->  cash  ->  slot rewards (direct-or-pending)  ->  mark redeemed/claimed
```

- **Tools** are idempotent (`EnsureGearTool` no-ops if the tool is already
  present) so a retry can neither duplicate nor lose them.
- **Cash** (`EconomyService.AddMoney(..., 'CodeReward', {ApplyMultiplier =
  false})`) is validated before the call and cannot fail after it.
- **Slot rewards** (eggs/animals) either land in a reserved free slot or
  are persisted as **pending** entries. Pending counts as *safely committed*,
  never as a loss.
- The claim is marked **only after** all of the above.

### `CodesService` — redeem codes

- The catalog is **data**, not code. `CodesService` contains no
  `if code == "WELCOME"` anywhere — you add, disable, or expire a code by
  editing `Rewards.lua`.
- Normalization: trim + upper. `'welcome'`, `' WELCOME '` and `'WELCOME'`
  all resolve to the same entry.
- Validation order: exists → enabled → not expired → systems+profile
  present → per-player cap → global cap → reward shape valid → required
  systems present → grant.
- A **per-player/per-code mutex** (`tostring(userId) .. '\0' .. norm`) closes
  double-click and remote-spam races. The lock is set synchronously before
  any yield.
- Slot-bound rewards that cannot be delivered now (no free base slot) are
  queued in `data.PendingCodeRewards` and delivered later by the join hook
  and the sell hook.

### `DailyRewardsService` — the weekly streak

- **One pool per global week**, identical for every player on every server.
  The week/pool pair comes from `DailyRewardsWeek` (a DataStore-backed,
  atomically-selected global value with a deterministic fallback).
- The player's own progress lives in `data.DailyRewards`:
  `{ WeekId, Day, LastClaimAt }`. **`Day` is the NEXT claimable day**
  (1..7); `Day = 8` is the internal "week complete" sentinel.
- A day is `Claimed` **iff it was explicitly claimed** (`d < slice.Day`).
  Deriving "claimed" from `day <= currentDay` was a real bug that the
  current code explicitly avoids.
- On a new `WeekId` the slice resets to Day 1, **available but never
  auto-granted**. Progress never crosses weeks.
- Streak timing is `os.time()` only — client clocks are never trusted. A
  clock that moves **backwards** fails **closed** (the day stays locked until
  the anchor passes again).

### `PlaytimeRewardsService` — the session course

- Playtime is **session-scoped**: `os.clock() - session.start`. It is
  **never persisted** and never Heartbeat-ticked into the profile. AFK
  counts — there is no activity tracking by design.
- Leaving **discards the session**. Rejoining starts at 0 but does **not**
  re-grant already-claimed milestones.
- Pool selection (one pool per session):
  - **Resume** — the persisted `DayId` equals today's and the course is not
    complete → same pool, claimed set preserved, playtime restarts at 0.
  - **Completed course** → the next session picks a *personal* random pool,
    excluding the completed one when alternatives exist. This is the one
    documented exception to "everyone gets the same pool"; it never touches
    other players' live sessions.
  - **Fresh profile / new IST day** → today's global pool.
  - **Mid-session** the pool **never changes**, even if IST midnight passes
    while the player is online.
- Milestones are **cumulative**: claiming one does not reset the clock and
  does not touch its siblings. Several can be `Claimable` at once; each is
  claimed individually.

### `PlaytimeRewardsDay` — the global daily pool

- One pool per **IST calendar day** (00:00 Asia/Kolkata), identical on every
  server, surviving restarts.
- Selected **inside `UpdateAsync`**, which is atomic per key: servers
  reaching a new day simultaneously serialize, the loser re-runs against the
  winner's committed value, and exactly one pool wins.
- If the DataStore is unreachable, a **deterministic hash** of the `DayId`
  over the catalog is used instead, skipping the previous day's hash pick
  when alternatives exist.

### `DailyRewardsWeek` — the global weekly pool

- Picks **exactly one 7-day reward pool per global week**, and that choice
  is **identical** on every server in the fleet, **identical** for every
  player, **stable** for the whole week, and **surviving** server restarts.
- It is the **global half** of the daily-rewards feature. The per-player
  half (the streak, the claim timer, the grants) lives in
  `DailyRewardsService`.
- The selection runs inside `UpdateAsync`, which is **atomic per key**: when
  two servers reach a new week simultaneously, their transforms serialize —
  the loser re-runs against the winner's committed value, sees its `WeekId`
  already set to the new week, and keeps it. **Exactly one pool wins;
  there is no split brain.**
- If the DataStore is unreachable (e.g. Studio without API access), a
  **deterministic fallback** is used: `poolIndex = hash(WeekId)` over the
  catalog, skipping the previous week's hash pick when more than one pool
  exists. The same input week gives the same pool on every server with zero
  storage.
- **The week anchor** is an epoch-anchored global week index:
  `('W%06d'):format(math.floor(os.time() / 604800))`. Because the anchor is
  a fixed divisor of the Unix epoch, the boundaries fall on **Thursday 00:00
  UTC**. The anchor never moves, so every server trivially agrees on "this
  week" without any coordination. This is a deliberate, non-obvious choice:
  a Thursday boundary means the "week" does not align with the calendar
  week most players think of.
- **The avoid-repeat promise:** with more than one pool configured, the newly
  selected pool never equals the stored `PreviousPoolId`. **Only
  back-to-back repeats are excluded** — week N+1 may reuse week N-1's pool. A
  single-pool catalog trivially repeats. The fallback path can only do
  **best-effort** here: it knows the hash chain (it can compute what last
  week's hash pick was) but not a stored `PreviousPoolId`, so the no-repeat
  guarantee is weaker without the DataStore.
- `DailyRewardsService` calls `Current()` per request (an O(1) integer
  compare on a cache hit) and broadcasts fresh **per-player** snapshots
  when the week rolls over.

---

## Entry Points

| Entry point | Kind | Notes |
|---|---|---|
| `CodesService.Init()` | Server | Validates the live catalog (warn-only) and wires the `CodesAction` remote. Idempotent. |
| `CodesService.Redeem(player, codeText): table` | Server | The one authoritative redeem path. Returns `{Success, Reason?, Message?, RewardText?}`. |
| `CodesService.RedeemInner(player, userId, norm): table` | Server | The validation + grant core, after normalization. Public so it can be tested; call `Redeem` instead. |
| `CodesService.OnPlayerReady(player)` | Server | Join hook: normalizes the profile slice and attempts pending delivery. |
| `CodesService.TryDeliverPending(userId): boolean` | Server | Attempts every queued reward. Returns `true` if at least one landed. |
| `CodesService.DeliverEggReward(userId, data, codeLabel, rarity): table` | Server | The **shared** egg delivery. Used by Daily and Playtime. Returns `{ok, queued, failed}`. |
| `CodesService.DeliverAnimalReward(userId, data, codeLabel, defId, trait?, level?): table` | Server | The **shared** animal delivery. Same return shape. |
| `CodesService.QueuePendingReward(data, entry)` | Server | Appends a pending entry to `data.PendingCodeRewards`. |
| `CodesService.NormalizePlayer(userId)` | Server | Load-time + join-time repair of the Codes profile slice. Drops malformed pending entries. |
| `CodesService.ForgetPlayer(userId)` | Server | Clears the player's locks and the pending-delivery guard. |
| `CodesService.SetPlayerService/SetEconomyService/SetSlotService/SetEggService/SetAnimalService/SetGearShopService` | Server | Late-bound injection. |
| `CodesService._TestReset()` | Test | Clears the locks and the delivering guard. |
| `DailyRewardsService.Init()` | Server | Validates the live daily config (warn-only) and wires `DailyRewardsAction`. Idempotent. |
| `DailyRewardsService.GetSnapshot(userId, nowOverride?): table?` | Server | The authoritative per-player snapshot. `nil` if the profile or the week is unavailable. |
| `DailyRewardsService.PushState(player)` | Server | Pushes the snapshot to the client. |
| `DailyRewardsService.Claim(player, clickedDay): table` | Server | The one authoritative single-day claim. `clickedDay` is validated but never trusted. |
| `DailyRewardsService.ClaimInner(player, userId, clickedDay): table` | Server | The validation core of the above. |
| `DailyRewardsService.ClaimAll(player): table` | Server | Skip-all. **Robux-gated** — requires a prior `GrantSkipAccess`. |
| `DailyRewardsService.ClaimAllInner(player, userId): table` | Server | The skip-all core. |
| `DailyRewardsService.GrantSkipAccess(player): boolean` | Server | Grants the session skip-all entitlement. Called **only** by the Shop receipt path. |
| `DailyRewardsService.ForgetPlayer(userId)` | Server | Clears the lock and the skip entitlement. |
| `DailyRewardsService.SetPlayerService/SetEconomyService/SetGearShopService/SetCodesService` | Server | Late-bound injection. |
| `DailyRewardsService._TestReset()` | Test | Clears locks + entitlements and resets `DailyRewardsWeek`. |
| `PlaytimeRewardsService.Init()` | Server | Validates the live playtime config (warn-only) and wires `PlaytimeRewardsAction`. Idempotent. |
| `PlaytimeRewardsService.GetSnapshot(userId): table?` | Server | The authoritative per-player snapshot. Resolves the session lazily. |
| `PlaytimeRewardsService.PushState(player)` | Server | Pushes the snapshot to the client. |
| `PlaytimeRewardsService.PushStateById(userId)` | Server | Pushes to a player looked up by UserId. Used by the threshold timers. |
| `PlaytimeRewardsService.OnPlayerReady(player)` | Server | Join hook: starts the session clock and arms the threshold pushes. |
| `PlaytimeRewardsService.Claim(player, index): table` | Server | The one authoritative milestone claim. `index` is validated but never trusted. |
| `PlaytimeRewardsService.ClaimInner(player, userId, index): table` | Server | The validation core of the above. |
| `PlaytimeRewardsService.ClaimAll(player): table` | Server | Skip-all. **Robux-gated** — requires a prior `GrantSkipAccess`. |
| `PlaytimeRewardsService.ClaimAllInner(player, userId): table` | Server | The skip-all core. |
| `PlaytimeRewardsService.GrantSkipAccess(player): boolean` | Server | Grants the session skip-all entitlement. Called **only** by the Shop receipt path. |
| `PlaytimeRewardsService.ForgetPlayer(userId)` | Server | Clears the session, the lock, and the skip entitlement. **Defined twice** in the source; the later definition wins. |
| `PlaytimeRewardsService.SetPlayerService/SetEconomyService/SetGearShopService/SetCodesService` | Server | Late-bound injection. |
| `PlaytimeRewardsService._TestReset()` | Test | Clears sessions/locks/entitlements and resets `PlaytimeRewardsDay`. |
| `PlaytimeRewardsDay.Current(nowOverride?): table` | Server | `{ DayId, PoolId, Source }` for the current IST day. `Source` is `'global'`, `'local-fallback'`, or `'misconfigured'`. |
| `PlaytimeRewardsDay.DayIndexAt(now): number` | Pure | The IST calendar-day index for a unix timestamp. |
| `PlaytimeRewardsDay._TestReset()` | Test | Clears the cache and the store handle. |
| `DailyRewardsWeek.Current(nowOverride?): table` | Server | `{ WeekId, PoolId, Source }` for the current global week. `Source` is `'global'`, `'local-fallback'`, or `'misconfigured'`. The only public function of the module. Never throws. |
| `DailyRewardsWeek._TestReset()` | Test | Clears the cache, the DataStore handle and the failure latch. Does not reset anything else (there is nothing else). |
| `DailyRewardsWeek` (module) | module | `table.freeze`d. Returned from `require(ServerScriptService.Daily.DailyRewardsWeek)`. |

Everything else in `DailyRewardsWeek.lua` is a module-local: `weekIndexAt`,
`weekIdOf`, `validPoolId`, `hashWeek`, `poolIds`, `deterministicPoolId`,
`randomPoolId`, `getStore`, `loadOrSelectGlobal`, `logWeek`. The module has
**no** remotes, **no** Studio assets, **no** profile fields and **no**
client-side code.

---

## Files

| Library path | Roblox destination | Purpose |
|---|---|---|
| `Source/ReplicatedStorage/Config/Economy/Rewards.lua` | `ReplicatedStorage.Config.Economy.Rewards` | The shared config: `.Codes` (catalog), `.Daily` (weekly pools), `.Playtime` (session pools). |
| `Source/ServerScriptService/Codes/CodesService.lua` | `ServerScriptService.Codes.CodesService` | The redeem-code system **and** the shared delivery pipeline used by Daily and Playtime. |
| `Source/ServerScriptService/Daily/DailyRewardsService.lua` | `ServerScriptService.Daily.DailyRewardsService` | The weekly 7-day streak. |
| `Source/ServerScriptService/Daily/DailyRewardsWeek.lua` | `ServerScriptService.Daily.DailyRewardsWeek` | The global weekly pool selector (DataStore-backed). 235 lines. `--!strict`. |
| `Source/ServerScriptService/Playtime/PlaytimeRewardsService.lua` | `ServerScriptService.Playtime.PlaytimeRewardsService` | The session 6-milestone course. |
| `Source/ServerScriptService/Playtime/PlaytimeRewardsDay.lua` | `ServerScriptService.Playtime.PlaytimeRewardsDay` | The global IST-day pool selector (DataStore-backed). |

`DailyRewardsWeek.lua` **must** stay a direct child of
`ServerScriptService/Daily/` — `DailyRewardsService` reaches it through
`require(script.Parent.DailyRewardsWeek)`.

---

## Configuration

The system's own config is `ReplicatedStorage/Config/Economy/Rewards.lua` —
it is **already included** in this folder, so it needs no separate copy
step. It is registered in `ConfigValidator._MODULES` as three domains:
`Economy.Rewards.Codes`, `Economy.Rewards.Daily`, `Economy.Rewards.Playtime`.

`Config.lua` in this folder is a **reference transcription** of the tunables
and the catalog. It is documentation, not a live module — nothing requires
it. To change a value, edit `Rewards.lua`.

| Section | Key | Default | Meaning |
|---|---|---|---|
| `Codes` | `CODES` | 8 entries | The code catalog. See below. |
| `Codes` | `MAX_SLOT_UNITS_PER_CODE` | `10` | Max eggs+animals one redemption may request, so a single code can never exhaust a base. Module-local, not exported. |
| `Daily` | `Settings.ClaimInterval` | `86400` (24 h) | Seconds between daily claims. Server `os.time()` only. |
| `Daily` | `WeeklyPools` | `Pool_A`, `Pool_B`, `Pool_C` | Three 7-day pools. Each pool has **exactly** 7 days (validated). |
| `Daily` | `DAYS_PER_POOL` | `7` | Module-local. Every pool must have exactly this many days. |
| `Playtime` | `Settings.SessionResetsOnLeave` | `true` | Documents the rule; **must** be `true` (the validator rejects `false`). |
| `Playtime` | `Settings.DailyResetTimezone` | `'Asia/Kolkata'` | The label for the day boundary. The arithmetic uses the offset below. |
| `Playtime` | `Settings.DailyResetHour` | `0` | Documented hour of the boundary. |
| `Playtime` | `Settings.DailyResetMinute` | `0` | Documented minute of the boundary. |
| `Playtime` | `Settings.SkipAllEnabled` | `false` | A validated flag. The services gate on the **entitlement**, not on this flag. |
| `Playtime` | `Settings.DayBoundaryOffsetSeconds` | `19800` | UTC+5:30. The real day-boundary arithmetic. **Pinned** by `ConfigValidator` and by `ConfigArchitecture.spec.lua`. |
| `Playtime` | `Pools` | `Pool_A`, `Pool_B`, `Pool_C` | Three 6-milestone courses. Every pool must have the **same** milestone count (the UI is fixed at 6). Thresholds must strictly ascend. |

### The week selector's module-locals

`DailyRewardsWeek.lua` has **no** external configuration surface — two of
its three tunables are module-locals in the file itself:

| Tunable | Default | Where to change it |
|---|---|---|
| DataStore name | `'p7_DailyRewards_Weekly_v1'` | `DailyRewardsWeek.lua:49` (`DATASTORE_NAME` — a module-local; you must edit the file) |
| DataStore key | `'CurrentWeek'` | `DailyRewardsWeek.lua:50` (`DATASTORE_KEY` — a module-local) |
| Week length | `604800` s (7 days) | `DailyRewardsWeek.lua:48` (`SECONDS_PER_WEEK` — a module-local) |
| Week anchor | Thursday 00:00 UTC | derived from `SECONDS_PER_WEEK`; change the `weekIndexAt` divisor/offset to move it |
| Pool catalog | `Pool_A` / `Pool_B` / `Pool_C` | `Rewards.lua` → `Daily.WeeklyPools` |

`SECONDS_PER_WEEK` is **not** a round number of days from a fixed
calendar anchor — it is `7 * 24 * 60 * 60` seconds since the Unix
epoch, which is what puts the boundary on Thursday.

### The code catalog

`Codes.NormalizeCode(x)` = trim + upper, and `NormalizeCode(entry.Code)`
**must** equal `entry.Id` (validated). So the code players type and the id
stored in the profile are the same string.

| Id | Enabled | Expires | Rewards |
|---|---|---|---|
| `WELCOME` | yes | never | Cash `'2500'` |
| `CODE_CASH_TEST` | **no** | never | Cash `'5000'` |
| `CODE_EGG_TEST` | **no** | never | 1 `Common` Egg |
| `CODE_MULTI_TEST` | **no** | never | Cash `'1000'` + 1 `Divine` Egg |
| `CODE_TOOL_TEST` | **no** | never | 1 `SpeedCoil` tool |
| `CODE_ANIMAL_TEST` | **no** | never | 1 `Chicken` (Level 1) |
| `CODE_EXPIRED_TEST` | yes | `ExpiresAt = 1` (1970) | Cash `'100'` |
| `CODE_DISABLED_TEST` | **no** | never | Cash `'100'` |

The `*_TEST` entries are **test fixtures**, disabled by design. `WELCOME` is
the only live code.

> **Security:** the redemption codes themselves are **environment-specific
> game content, not secrets**, but they must not be committed to a public
> repository for a live game. A new game should author its own catalog (see
> *Adapting to a New Game*) and, if the codes are meant to be secret, inject
> them from a private config or a server-side datastore rather than
> committing them. This system has **no API keys, tokens, or webhook URLs**
> of any kind.

### The reward shape

One shape, shared by all three sections, validated by
`Codes.ValidateRewards`:

```lua
{
    Cash    = '<BigNumber decimal string>',       -- optional
    Eggs    = { { Rarity = 'Rare', Amount = 1 } }, -- optional
    Tools   = { { Id = 'SpeedCoil', Amount = 1 } },-- optional
    Animals = { { DefId = 'Chicken', Trait = 'Cute',
                   Level = 1, Amount = 1 } },       -- optional
}
```

Rules: at least one category; `Cash` must be a valid BigNumber string; egg
rarities must exist in `Eggs.Price`; tool ids must exist in
`Gear.FindGear`; animal def ids must exist in `Animals.Get`; traits must
exist in `Traits.Get`; `Level` must be a positive integer (default 1);
`Amount` must be a positive integer; eggs + animals together must not
exceed `MAX_SLOT_UNITS_PER_CODE` (10).

---

## Dependencies

See `Dependencies.md` for the full list. The load-bearing ones:

- `ReplicatedStorage.Config.Economy.Rewards` — the catalog and both
  matrices (this system's own config).
- `ReplicatedStorage.Config.Creatures.Eggs` / `.Animals` / `.Traits` —
  reward-id validation.
- `ReplicatedStorage.Config.Economy.Gear` — tool display names and
  validation.
- `ServerScriptService.Codes.CodesService` — **the shared delivery
  pipeline**. Daily and Playtime both call `DeliverEggReward` /
  `DeliverAnimalReward` / `QueuePendingReward` on it. There is no second
  egg inventory.
- `ServerScriptService.Base.NotificationService` — every player-facing
  message and SFX.
- `ServerScriptService.Utility.MoneyIcon` — the cash-burst icon.
- `ServerScriptService.FunnelService` — analytics (leaf; never
  gameplay-critical).
- `ServerScriptService.Daily.DailyRewardsWeek` — the global week/pool
  selector. **In-system**: it ships in this folder at
  `Source/ServerScriptService/Daily/DailyRewardsWeek.lua`, and
  `DailyRewardsService` requires it (through `script.Parent`) at the top
  of that file. It also requires `ReplicatedStorage.Config.Economy.Rewards`
  (`.Daily` — the pool catalog) and `ReplicatedStorage.Utility.Debug`.

---

## Initialization Order

```text
1.  Remotes folder created (bootstrap.createRemotes)
2.  PlayerService.Init()
    EconomyService.Init() + SetPlayerService
    SlotService.Init()
    EggService.Init()
    AnimalService.Init()
    GearShopService.SetPlayerService / SetEconomyService / Init
    NotificationService.Init() + SetPlayerService
3.  CodesService.SetPlayerService(PlayerService)
    CodesService.SetEconomyService(EconomyService)
    CodesService.SetSlotService(SlotService)
    CodesService.SetEggService(EggService)
    CodesService.SetAnimalService(AnimalService)
    CodesService.SetGearShopService(GearShopService)
    CodesService.Init()                -- wires CodesAction
4.  DailyRewardsService.SetPlayerService(PlayerService)
    DailyRewardsService.SetEconomyService(EconomyService)
    DailyRewardsService.SetGearShopService(GearShopService)
    DailyRewardsService.SetCodesService(CodesService)
    DailyRewardsService.Init()         -- wires DailyRewardsAction
                                       -- (requires DailyRewardsWeek)
5.  PlaytimeRewardsService.SetPlayerService(PlayerService)
    PlaytimeRewardsService.SetEconomyService(EconomyService)
    PlaytimeRewardsService.SetGearShopService(GearShopService)
    PlaytimeRewardsService.SetCodesService(CodesService)
    PlaytimeRewardsService.Init()      -- wires PlaytimeRewardsAction
```

`CodesService.Init()` must come **before** `DailyRewardsService.Init()` and
`PlaytimeRewardsService.Init()` only in the sense that the latter two need
`CodesService` injected — which happens at their `SetCodesService` step.
The `Init()` calls themselves are independent.

**`DailyRewardsWeek` has no initialization order of its own.** It has no
`Init()`, no `Start()` and no setters — it is `require`d on demand and
every call is self-contained:

```text
DailyRewardsService.Init()  ->  requires ServerScriptService.Daily.DailyRewardsWeek
```

The only requirement is a **filesystem** one: the file must **exist** at
`ServerScriptService/Daily/DailyRewardsWeek.lua` before
`DailyRewardsService` is required, because the require is at the top of
that file and is not deferred. The DataStore handle is created **lazily**
on the first `Current()` call that misses the cache — there is no boot-time
connection and no retry loop.

### Runtime hooks

| Event | Call | Where |
|---|---|---|
| Player joined | `CodesService.OnPlayerReady(player)` | bootstrap `:934` — after base restore + offline earnings, before `MarkLoaded`. |
| Player joined | `PlaytimeRewardsService.OnPlayerReady(player)` | bootstrap `:938` — starts the session clock + arms the threshold pushes. |
| Player left | `CodesService.ForgetPlayer(userId)` | bootstrap `:1257` |
| Player left | `DailyRewardsService.ForgetPlayer(userId)` | bootstrap `:1259` |
| Player left | `PlaytimeRewardsService.ForgetPlayer(userId)` | bootstrap `:1263` |
| A base slot was freed | `CodesService.TryDeliverPending(userId)` | `SellService.lua:507` |
| Admin command | `CodesService.TryDeliverPending(player.UserId)` | `Cmdr/Server/Commands/deliverPendingServer.lua:35` |
| Robux receipt (Skip Daily) | `DailyRewardsService.GrantSkipAccess(player)` | `ShopService.lua:278` → then `ClaimAll`. |
| Robux receipt (Skip Playtime) | `PlaytimeRewardsService.GrantSkipAccess(player)` | `ShopService.lua:295` → then `ClaimAll`. |

**There is no `DailyRewardsService.OnPlayerReady`.** The daily service has
no join hook; streak state is pulled on demand by `GetSnapshot`, and its
slot-bound rewards reuse the Codes pending queue.

---

## Data

### Profile fields

| Key | Type | Owner | Meaning |
|---|---|---|---|
| `RedeemedCodes` | `{[string]: number}` | `CodesService` | Redemption count per normalized code id. `data.RedeemedCodes[norm] = count`. |
| `PendingCodeRewards` | array of pending entries | `CodesService` | FIFO queue of slot-bound rewards awaiting a free base slot. Shared by all three systems. |
| `DailyRewards` | `{WeekId: string, Day: number, LastClaimAt: number}` | `DailyRewardsService` | The daily streak slice. `Day` is the NEXT claimable day (1..7); `8` = week complete. |
| `PlaytimeRewards` | `{DayId: string, PoolId: string, Claimed: {[number]: boolean}, Completed: boolean}` | `PlaytimeRewardsService` | The playtime course slice. Raw playtime is **not** stored. |

### Pending entry shape

```lua
{ Code = '<label>', Kind = 'Egg' | 'Animal',
  -- Egg:    Rarity = '<Eggs rarity>'
  -- Animal: DefId = '<Animals id>', Trait = <string|nil>, Level = <number|nil> }
```

`Code` is a **label**, not necessarily a redeemable code id: Daily uses
`'DAILY_<PoolId>_D<n>'` and Playtime uses `'PLAYTIME_<PoolId>_M<n>'`.

### DataStore

| Store | Key | Value | Used by |
|---|---|---|---|
| `p7_DailyRewards_Weekly_v1` | `'CurrentWeek'` | `{WeekId, PoolId, PreviousPoolId, SetAt}` | `DailyRewardsWeek` |
| `p7_PlaytimeRewards_Daily_v1` | `'CurrentDay'` | `{DayId, PoolId, PreviousPoolId, SetAt}` | `PlaytimeRewardsDay` |

Both names are **hardcoded literals**. A new game MUST change them. The
weekly store name and key are module-locals in `DailyRewardsWeek.lua`
(lines 49 and 50) — there is no external config surface for them.

### In-memory state of `DailyRewardsWeek`

| State | Shape | Reset by |
|---|---|---|
| `cache` | `{ weekIndex: number, weekId: string, poolId: string, source: string }` | `_TestReset()`, or automatically when the week index changes |
| `storeHandle` | `DataStore?` | `_TestReset()` |
| `storeFailed` | `boolean` | `_TestReset()` |

`storeFailed` is a **latch**: once `GetDataStore` fails, the module never
retries for the lifetime of the server. There is no backoff and no
retry — the deterministic fallback covers the outage instead.

`DailyRewardsWeek` reads and writes **no** player profile.

---

## Known Limitations

- **`DailyRewardsWeek` must stay a direct child of
  `ServerScriptService/Daily/`.** The `DailyRewardsService` does
  `require(script.Parent.DailyRewardsWeek)`, so moving the file elsewhere
  breaks the require. It is now in this folder at
  `Source/ServerScriptService/Daily/DailyRewardsWeek.lua`.
- **The `DailyRewardsWeek` DataStore failure latch never resets.** If
  `DataStoreService:GetDataStore` throws once (typically in Studio without
  API access), the module silently uses the deterministic fallback for the
  rest of the server's life. A developer who enables API access
  mid-session still gets the fallback until the server restarts.
- **The weekly fallback's avoid-repeat is best-effort.** Without the
  DataStore there is no `PreviousPoolId`, so the fallback only avoids
  repeating the *previous week's hash pick* — which is not the same thing
  as avoiding the pool that was actually served last week.
- **The weekly boundary is Thursday 00:00 UTC**, not the calendar week.
  Players in most timezones will experience a mid-week rollover.
- **The whole week is one pool for everyone.** There is no per-player or
  per-server variation, and no way to run a second, parallel weekly
  rotation without a second DataStore key and a second module.
- **The weekly selection uses `math.random` without seeding.** The
  selection only happens inside `UpdateAsync`, so the exact winner depends
  on Roblox's global RNG state at the moment of the call. This is fine
  (exactly one server's roll wins) but it means the selection is not
  reproducible from the week id alone — you cannot compute the pool
  offline.
- **`DailyRewardsWeek`'s `Debug.Warn` is called with the wrong tag
  shape.** Line 222 calls `Debug.Warn('DailyRewardsWeek', ...)` — using
  the module name as the tag — while every other call in the file uses the
  `'DRW'` tag. If you enable a per-tag whitelist in `Systems.Debug`, the
  misconfiguration warning will be **filtered out** unless you add
  `DailyRewardsWeek` to the whitelist as well as `DRW`.
- **A weekly misconfiguration is cached for the whole week.** The miss is
  cached with the week's index, so fixing the catalog mid-week does not
  help until the week rolls over or `_TestReset()` is called.
- **There are no tests for `DailyRewardsWeek`.** The module's only test
  seam is `_TestReset()`, which `DailyRewardsService._TestReset()` also
  calls (so a spec that resets the daily service also resets this
  module).
- **The weekly `Source` field is informational only.** Nothing in the game
  branches on `Source === 'local-fallback'`. A week served from the
  fallback is indistinguishable to players from a global week.
- **`MaxGlobalRedemptions` is best-effort and per-server only.** It is an
  in-memory counter (`globalCounts`), resets on server restart, and is not
  shared across servers. The code deliberately reports it as the `disabled`
  reason, not a distinct one.
- **`PlaytimeRewardsService.ForgetPlayer` is defined twice** in the source
  (`PlaytimeRewardsService.lua:477` and `:723`). The later definition wins
  at runtime; the earlier one is dead code. The later one also clears
  `_skipAccess`, which the earlier one did not.
- **Playtime is session-only and AFK counts.** Leaving discards it, and
  there is no activity/idle tracking, so a player who walks away still
  accrues playtime.
- **The daily course is per-player, the pool is per-week.** The pool is
  globally identical, but each player's *progress* through it is their own,
  and a player can be several days behind.
- **The daily `ClaimInterval` is 24 h from the last claim**, not from a
  calendar midnight. A player who claims at 23:00 waits 24 h, not until
  tomorrow's midnight.
- **`ComputeStatus` fails closed on a backwards clock** — the day stays
  locked until the original anchor passes again. That is deliberate, but it
  means a server with a badly wrong clock can lock a player out.
- **Tools granted by a code are session-only.** `EnsureGearTool` gives a
  `Tool` instance, not a persisted entitlement; tools are never persisted
  in this game.
- **Slot-bound rewards are capped at 10 units per code.** Overflow belongs
  in follow-up codes, not in one code.
- **The `Codes` catalog ids are visible in server logs** (`logCode` prints
  the normalized code). Do not treat a code as a secret if you need it to
  be one.
- **`DailyRewardsService` has a duplicated `if day > DayCount()` check** in
  `computeStatus` (`:198` and `:200`) — harmless dead code.
- **`checkInvariants` only warns.** A state invariant violation is logged
  loudly but the state is still returned (fail-open display, fail-closed
  grants — `ClaimInner` revalidates).
- **Skip-all is Robux-gated but the entitlement is session-only.** A player
  who buys the skip and then leaves loses the entitlement.
- **No client-side UI is included.** The client GUIs (Codes panel, Daily
  panel, Playtime panel) live in the `ClientPresentation` system and are not
  part of this system.

---

## Testing

- `Tests/RewardSkipAll.spec.lua` — the skip-all entitlement contract. It
  fakes the injected services via `Set*Service` and asserts:
  - `ClaimAll` grants the whole week, then a second `ClaimAll` grants
    nothing (idempotent).
  - A single `Claim` followed by `ClaimAll` grants only the remainder.
  - `ClaimAll` without an entitlement returns `Success == false` with
    `Reason == 'no-access'`.

The specs require Roblox Studio (TestEZ). No DataStore is touched. See
`../../Tests/README.md`.

### Testing `DailyRewardsWeek`

**There are no tests for it.** The source game's `Tests/` tree has no
`DailyRewardsWeek.spec.lua`, and this folder has no spec covering it.

The module's only test seam is `_TestReset()`, which
`DailyRewardsService._TestReset()` also calls (so a spec that resets the
daily service also resets this module).

### How to test it manually

In Studio, with **Game Settings → Security → Enable Studio Access to API
Services** ON:

```lua
local Week = require(ServerScriptService.Daily.DailyRewardsWeek)

print(Week.Current().WeekId)    -- e.g. 'W002994'
print(Week.Current().PoolId)    -- e.g. 'Pool_B'
print(Week.Current().Source)    -- 'global' | 'local-fallback' | 'misconfigured'
```

- Call `Current()` twice in the same week → identical results, and the
  second call does **not** hit the DataStore (the cache short-circuits).
- Restart the server mid-week → the same `PoolId` comes back, because the
  DataStore committed it.
- Turn API access **off** and restart → `Source` becomes
  `'local-fallback'` and the pool is the deterministic hash pick; the same
  week still yields the same pool on another server with API access off.

A minimal spec, if you want one, would assert that `Current()` is pure
with respect to `nowOverride`: `Current(t)` and `Current(t + 604800)` must
return different `WeekId`s but the same `PoolId` within one week.

---

## Adapting to a New Game

1. **Copy the six files** to their documented Roblox paths
   (`Dependencies.md` → *Files*). `DailyRewardsWeek.lua` is included —
   it lives in this folder at
   `Source/ServerScriptService/Daily/DailyRewardsWeek.lua` and must land
   at `ServerScriptService/Daily/DailyRewardsWeek.lua`, a direct sibling
   of `DailyRewardsService.lua`.
2. **Copy the config** to `ReplicatedStorage/Config/Economy/Rewards.lua`.
   If you already have a `Rewards` domain, merge the three sections into it
   — the services require `ReplicatedStorage.Config.Economy.Rewards` and
   take `.Codes` / `.Daily` / `.Playtime` from it.
3. **Replace the code catalog** with your own. Set `Id == Code` (already
   upper-case), set `Enabled = true` only for live codes, and delete the
   `*_TEST` fixtures or keep them disabled.
4. **Replace the reward contents** with your own ids. Every egg rarity must
   exist in your `Eggs.Price`, every tool id in your `Gear.FindGear`, every
   animal def id in your `Animals.Get`, every trait in your `Traits.Get`.
   `ConfigValidator` will tell you at boot if any of them do not.
5. **Change both DataStore names** to your own
   (`p7_DailyRewards_Weekly_v1`, `p7_PlaytimeRewards_Daily_v1`). The
   weekly one is a module-local at `DailyRewardsWeek.lua:49` — edit it in
   place. The `p7_` prefix is the source game's identifier; the names must
   be unique per game and per environment.
6. **Decide the weekly rollover day.** `DailyRewardsWeek.lua:48`
   (`SECONDS_PER_WEEK`) is the anchor divisor, and it puts the boundary on
   **Thursday 00:00 UTC**. For a **Monday 00:00 UTC** boundary, edit
   `weekIndexAt` to `math.floor((now + 345600) / 604800)` (345600 s = 4
   days) — note that this requires editing `weekIndexAt`, not just the
   constant.
7. **Decide the day boundary.** `Playtime.Settings.DayBoundaryOffsetSeconds`
   is the real arithmetic; `DailyResetTimezone` / `DailyResetHour` /
   `DailyResetMinute` are documentation. If you want UTC midnight, set the
   offset to `0` and the timezone label to `'UTC'`. **You must change both**
   or the invariant check will not match the label.
8. **Decide the daily shape.** `DAYS_PER_POOL` is `7` and validated
   exactly. If you want 14 or 30 days, change the constant *and* the UI.
9. **Decide the playtime shape.** Every pool must have the **same**
   milestone count (the UI is fixed). Thresholds must strictly ascend
   within a pool.
10. **Wire the bootstrap** in the order in *Initialization Order*, and wire
   the three runtime hooks (`OnPlayerReady`, `ForgetPlayer`,
   `TryDeliverPending`).
11. **Wire the skip-all entitlement** if you monetize it: the Shop receipt
    path calls `GrantSkipAccess(player)` and then `ClaimAll(player)`. A bare
    `ClaimAll` remote with no entitlement is rejected with `no-access`.
12. **Do not trust the client.** The `Day` / `Index` fields on the action
    payloads are UX/debug only. The server recomputes them. If you add a
    new remote, keep the same discipline: intent in, state out.
