# CodesAndRewards — Setup

Installing this system into a new Rojo project.

Assumes a fresh Rojo project with `default.project.json` mapping `src/`
onto the game root, and that the **PlayerData**, **Economy**,
**Slots**, **Eggs**, **Animals**, **Gear**, **Notifications**,
**SharedUtilities** and **Remotes** systems are already installed (see
`Dependencies.md`).

---

## 1. Copy the files

The library's `Source/` tree already mirrors the Roblox paths, so the
copy is 1:1.

```bash
SRC=ReusableSystems/Systems/CodesAndRewards/Source
DST=your-project/src

mkdir -p "$DST/ServerScriptService/Codes"
mkdir -p "$DST/ServerScriptService/Daily"
mkdir -p "$DST/ServerScriptService/Playtime"
mkdir -p "$DST/ReplicatedStorage/Config/Economy"

cp "$SRC/ServerScriptService/Codes/CodesService.lua"        "$DST/ServerScriptService/Codes/"
cp "$SRC/ServerScriptService/Daily/DailyRewardsService.lua"  "$DST/ServerScriptService/Daily/"
cp "$SRC/ServerScriptService/Daily/DailyRewardsWeek.lua"     "$DST/ServerScriptService/Daily/"
cp "$SRC/ServerScriptService/Playtime/PlaytimeRewardsService.lua" "$DST/ServerScriptService/Playtime/"
cp "$SRC/ServerScriptService/Playtime/PlaytimeRewardsDay.lua"     "$DST/ServerScriptService/Playtime/"
cp "$SRC/ReplicatedStorage/Config/Economy/Rewards.lua"      "$DST/ReplicatedStorage/Config/Economy/"
```

That is the whole system — **six** files. `DailyRewardsWeek.lua` is
included in this folder, so there is no second system to install.

### 1a. `DailyRewardsWeek.lua` — a hard in-system dependency

`DailyRewardsService.lua` does `require(script.Parent.DailyRewardsWeek)`
at the top of the file. The require is **not** deferred, so
`DailyRewardsService` cannot be required at all without this file
present. **Without it the require fails at load and the daily rewards
system never starts.**

Because the consumer reaches it through `script.Parent`, the file must
be a **direct child** of `ServerScriptService/Daily/` — i.e. a sibling
of `DailyRewardsService.lua`. Do **not** put it in a `Recipes` folder
or anywhere else; the `script.Parent` require would fail to resolve.

The file is byte-identical to the source game's
`src/ServerScriptService/Daily/DailyRewardsWeek.lua` (md5
`c1493292e580a6b8e0b5c27c51bc6b12`) and has **no** separate
configuration surface — see *3f* below for the two module-locals you
must edit in place.

### 1b. Required config siblings

`Rewards.lua` requires four other config modules by relative path:

| Module | Roblox path | From |
|---|---|---|
| `Eggs` | `ReplicatedStorage.Config.Creatures.Eggs` | the Eggs system |
| `Animals` | `ReplicatedStorage.Config.Creatures.Animals` | the Animals system |
| `Traits` | `ReplicatedStorage.Config.Creatures.Traits` | the Animals system |
| `Gear` | `ReplicatedStorage.Config.Economy.Gear` | the Economy system |
| `BigNumber` | `ReplicatedStorage.Utility.BigNumber` | SharedUtilities |

`Rewards.lua` uses relative requires (`script.Parent.Parent.Creatures.Eggs`),
so the **directory layout must match exactly**: `Rewards.lua` must live
at `ReplicatedStorage/Config/Economy/` for `script.Parent.Gear` to
resolve to `Config/Economy/Gear`.

---

## 2. Third-party packages (Wally)

**None.** This system has no external dependencies. It uses only Roblox
engine services and first-party modules.

---

## 3. Configure

### 3a. The rewards catalog — `src/ReplicatedStorage/Config/Economy/Rewards.lua`

This is the only file you must author for the system to be meaningful.
It has three sections.

**`Codes`** — the redeem catalog:

```lua
CODES = {
    { Id = 'WELCOME', Enabled = true, ExpiresAt = nil, MaxPerPlayer = 1,
      Cash = '2500' },
}
```

Rules the validator enforces (a violation is a **Studio boot error**):

- `Id` must be a non-empty, already-**UPPERCASE** string, unique.
- `Code` (if present) must normalize to `Id` — `NormalizeCode` is
  trim + upper.
- `Enabled` must be a boolean.
- `ExpiresAt` must be `nil` or a positive unix timestamp.
- `MaxPerPlayer` must be `nil` or a positive integer (default 1).
- `MaxGlobalRedemptions` must be `nil` or a positive integer.
- `Rewards` must be a valid reward table (see below).

**The reward shape** — one shape for codes, daily days and playtime
milestones:

```lua
Rewards = {
    Cash    = '2500',                                   -- BigNumber decimal STRING
    Eggs    = { { Rarity = 'Rare', Amount = 1 } },
    Tools   = { { Id = 'SpeedCoil', Amount = 1 } },     -- the stable GEAR id
    Animals = { { DefId = 'Chicken', Trait = 'Swift', Level = 1, Amount = 1 } },
}
```

- `Cash` is a **string**, never a number.
- `Eggs[].Rarity` must exist in `Eggs.Price`.
- `Tools[].Id` must exist in `Gear.FindGear` — the **gear id**, not the
  Tool instance name.
- `Animals[].DefId` must exist in `Animals.Get`; `Trait` must exist in
  `Traits.Get`; `Level` must be a positive integer.
- `Eggs` + `Animals` units together must not exceed
  `MAX_SLOT_UNITS_PER_CODE` (10).

**`Daily.WeeklyPools`** — the weekly daily course catalog:

```lua
DAILY_POOLS = {
    { Id = 'Pool_A', Days = {
        { [1] = { Rewards = { Cash = '1000' } } },
        { [2] = { Rewards = { Eggs = { { Rarity = 'Common', Amount = 1 } } } } },
        -- ... exactly 7 days
    } },
}
```

Every pool must have **exactly 7** days with contiguous keys `1..7`, and
every day's rewards must validate.

**`Playtime.Pools`** — the session course catalog:

```lua
PLAYTIME_POOLS = {
    { Id = 'Pool_A', Milestones = {
        { [1] = { RequiredPlaytime = 5 * 60,  Rewards = { Cash = '10000' } } },
        { [2] = { RequiredPlaytime = 10 * 60, Rewards = { Eggs = { { Rarity = 'Rare', Amount = 1 } } } } },
        -- ... exactly 6 milestones, strictly ascending RequiredPlaytime
    } },
}
```

Every pool must have the **same** milestone count and strictly ascending
`RequiredPlaytime` within itself.

### 3b. The playtime day boundary

`Playtime.Settings.DayBoundaryOffsetSeconds` (default `19800` = UTC+5:30)
is the real arithmetic. If you change it, change
`DailyResetTimezone` to match and update the pinned expectations in
`Shared/Utilities/ConfigValidator.lua` and `Tests/ConfigArchitecture.spec.lua`.

### 3c. DataStore names

Both names are hardcoded literals:

| Store | Owner | Where |
|---|---|---|
| `p7_DailyRewards_Weekly_v1` | `DailyRewardsWeek` | `Source/ServerScriptService/Daily/DailyRewardsWeek.lua:49` |
| `p7_PlaytimeRewards_Daily_v1` | `PlaytimeRewardsDay` | `Source/ServerScriptService/Playtime/PlaytimeRewardsDay.lua:45` |

**Rename both** for your game — the `p7_` prefix is the source game's
identifier. They must be unique per environment.

### 3d. Redemption codes are game content, not secrets

The code catalog is **environment-specific**. Two rules:

- Do **not** commit a live catalog to a public repository. Keep it in a
  private config module or inject it at boot, or accept that the codes
  are public.
- A code that appears in the server log (the `CD` debug tag) is not a
  secret. If you need secrecy, use signed/expiring tokens, not a plain
  string in a Lua table.

The system has **no API keys, tokens, webhooks or credentials** of any
kind. Nothing to configure securely beyond the catalog itself.

### 3e. Debug tags (optional)

The services log through the shared `Debug` module with the tags `'CD'`
(codes), `'DR'` (daily), `'PT'` (playtime), `'PTD'` (playtime day) and
`'DRW'` (the global week selector). Enable them per tag — see the
SharedUtilities docs. Debug output is **off by default**.

**One caveat for the week selector:** the misconfiguration warning at
`DailyRewardsWeek.lua:222` uses `'DailyRewardsWeek'` as the tag instead
of `'DRW'`. If you use a per-tag whitelist, add **both** `DRW` and
`DailyRewardsWeek`, or fix the call.

### 3f. The week selector's tunables — module-locals

`DailyRewardsWeek.lua` has **no** external configuration surface. Two
values are module-locals you must edit in the file itself.

**The DataStore name — required.** `DailyRewardsWeek.lua:49`

```lua
local DATASTORE_NAME = 'p7_DailyRewards_Weekly_v1'
```

Rename it to your game's namespace. It must be unique per game **and**
per environment (live vs. a test place). The `p7_` prefix is the source
game's identifier. The key is a module-local at line 50
(`'CurrentWeek'`).

**The week length / anchor — optional.** `DailyRewardsWeek.lua:48`

```lua
local SECONDS_PER_WEEK = 7 * 24 * 60 * 60
```

This is also the **anchor divisor**: `weekIndexAt(now) =
math.floor(now / SECONDS_PER_WEEK)`. Because 604800 seconds from the
Unix epoch lands on a **Thursday**, the weekly rollover happens at
**Thursday 00:00 UTC**.

To move the boundary to **Monday 00:00 UTC**, change the `weekIndexAt`
local (lines 68-70) to add a 4-day offset:

```lua
local function weekIndexAt(now: number): number
    return math.floor((now + 4 * 24 * 60 * 60) / SECONDS_PER_WEEK)
end
```

Changing `SECONDS_PER_WEEK` alone changes the *length* of the week but
not the *day* it starts on.

**The pool catalog** is owned by this system, not by the week selector:
`ReplicatedStorage/Config/Economy/Rewards.lua` →
`.Daily.WeeklyPools`. Every pool needs an `Id` and a `Days` array. The
selector only reads `Id`; the day contents are the consumer's business
(but this system's validator requires exactly 7 contiguous days per
pool).

---

## 4. Author the Studio assets

**None required for this system.** The three reward panels (Codes, Daily,
Playtime) are client GUI and belong to the **ClientPresentation** system.
The server side of this system needs no Workspace hierarchy.

The one soft dependency: `MoneyIcon.Resolve()` looks for
`Assets.Decals.MoneyIcon` (an `ImageLabel` with a non-empty `Image`) in
`ServerStorage` first, then `ReplicatedStorage`. If it is missing, the
`CashCollected` burst simply has no icon — nothing breaks.

---

## 5. Wire the bootstrap

The exact sequence, in the order it must happen.

### 5a. Prerequisites (before any of this system)

```lua
-- 1. Remotes must exist BEFORE any Init() that WaitForChild's on them.
createRemotes()   -- creates the Remotes folder from the Remotes registry

-- 2. The services this system grants into.
EconomyService.Init(); EconomyService.SetPlayerService(PlayerService)
PlayerService.Init()
SlotService.Init()
EggService.Init()
AnimalService.Init()
GearShopService.SetPlayerService(PlayerService)
GearShopService.SetEconomyService(EconomyService)
GearShopService.Init()
NotificationService.Init(); NotificationService.SetPlayerService(PlayerService)
```

### 5b. This system

```lua
-- Codes
CodesService.SetPlayerService(PlayerService)      -- :541
CodesService.SetEconomyService(EconomyService)    -- :542
CodesService.SetSlotService(SlotService)          -- :543
CodesService.SetEggService(EggService)            -- :544
CodesService.SetAnimalService(AnimalService)      -- :545
CodesService.SetGearShopService(GearShopService)  -- :546
CodesService.Init()                               -- :547

-- Daily (SetCodesService BEFORE Init)
DailyRewardsService.SetPlayerService(PlayerService)     -- :554
DailyRewardsService.SetEconomyService(EconomyService)     -- :555
DailyRewardsService.SetGearShopService(GearShopService)   -- :556
DailyRewardsService.SetCodesService(CodesService)         -- :557
DailyRewardsService.Init()                                -- :558

-- Playtime (SetCodesService BEFORE Init)
PlaytimeRewardsService.SetPlayerService(PlayerService)     -- :562
PlaytimeRewardsService.SetEconomyService(EconomyService)     -- :563
PlaytimeRewardsService.SetGearShopService(GearShopService)   -- :564
PlaytimeRewardsService.SetCodesService(CodesService)         -- :565
PlaytimeRewardsService.Init()                                -- :566
```

**`DailyRewardsWeek` needs no bootstrap wiring.** It has no `Init()`, no
`Start()` and no setters — it is `require`d on demand by
`DailyRewardsService` and every call is self-contained. The only thing
you must ensure is that the file is **on disk at the right path** before
that require runs. The DataStore handle is created lazily on the first
cache-missing `Current()` call.

### 5c. Runtime hooks

```lua
Players.PlayerAdded:Connect(function(player)
    -- after base restore + offline earnings, before MarkLoaded
    CodesService.OnPlayerReady(player)          -- bootstrap :934
    PlaytimeRewardsService.OnPlayerReady(player) -- bootstrap :938
end)

Players.PlayerRemoving:Connect(function(player)
    CodesService.ForgetPlayer(player.UserId)          -- :1257
    DailyRewardsService.ForgetPlayer(player.UserId)    -- :1259
    PlaytimeRewardsService.ForgetPlayer(player.UserId) -- :1263
end)
```

And in the **Sell** path, when a base slot is freed:

```lua
CodesService.TryDeliverPending(player.UserId)   -- SellService.lua:507
```

And in the **Shop** receipt path, after Roblox confirms payment:

```lua
DailyRewardsService.GrantSkipAccess(player)     -- ShopService.lua:278
PlaytimeRewardsService.GrantSkipAccess(player)  -- ShopService.lua:295
```

**Do not** call `GrantSkipAccess` from the client or from a remote. It is
the entitlement gate for the paid skip-all.

### 5d. Register the config domains

The central validator (`Shared/Utilities/ConfigValidator.lua`) must
register all three domains, or a bad catalog is not caught at boot:

```lua
Economy.Rewards.Codes
Economy.Rewards.Daily
Economy.Rewards.Playtime
```

Each exposes `Validate(): { string }` and returns an empty array when
clean. A Studio boot with a validation failure is a **hard error**; a
live server only **warns**.

---

## 6. Smoke test

Run in Studio with **Game Settings → Security → Enable Studio Access to
API Services** ON (both selectors use a DataStore).

### 6a. Codes

1. Join. The Output window should show `[Codes] Init done` (only with
   the `CD` tag enabled) and **no** `[Codes] Config issue:` lines.
2. Open the Codes panel, type `WELCOME`, press Redeem.
   - Expect: a success toast, the money count-up in the money pool, and
     `Money` increased by exactly `2500` (no multiplier — code rewards
     use `ApplyMultiplier = false`).
3. Redeem `WELCOME` again → `Codes_AlreadyRedeemed` warning, no grant.
4. Redeem `nonsense` → `Codes_InvalidCode` warning.
5. Redeem a **lowercase** `welcome` → it must succeed (normalization).
6. Redeem with a whitespace-padded `'  WELCOME  '` → it must succeed
   too.
7. Send a forged payload
   `{ Action = 'Redeem', Code = 'WELCOME', Cash = '999999' }` → the extra
   fields must be **ignored**; the grant must be the configured `2500`.
8. Re-enable `CODE_EGG_TEST` locally and redeem it with a **full
   base** → expect the success toast to end with
   `(queued: free a base slot!)`, then sell/remove an animal and
   confirm the egg arrives and the `Codes_PendingDelivered` toast
   fires.

### 6b. Daily

1. Open the Daily panel → the server pushes a snapshot; day 1 is
   `Claimable` on a fresh profile.
2. Claim day 1 → cash/egg granted, the panel advances to day 2, day 1
   becomes `Claimed`.
3. Claim again immediately → `Daily_NotReady` (the 24 h window).
4. Click day 5 (locked) → `Daily_NotReady`; nothing is granted.
5. To test the timer without waiting: `DailyRewardsService.Claim(player, 1)`
   on a profile whose `DailyRewards.LastClaimAt` is older than 24 h
   grants immediately.

### 6c. Playtime

1. Join → the session starts. The panel shows `Playtime = 0`.
2. Wait for the first milestone (5 minutes by default) — a state push
   fires on its own, so the topbar alert turns on without opening the
   panel.
3. Claim it → the reward lands, the milestone becomes `Claimed`, and
   the playtime clock is **not** reset.
4. Claim a locked milestone → `Playtime_NotReady`.
5. Leave and rejoin → the playtime counter **restarts at 0** (session
   based) but the claimed set survives for the same day.

### 6d. Skip-all entitlement

1. Call `PlaytimeRewardsService.ClaimAll(player)` **without**
   `GrantSkipAccess` → expect `Reason = 'no-access'` and a
   `Shop_SkipRequired` warning. Nothing is granted.
2. Call `GrantSkipAccess(player)` then `ClaimAll(player)` → the
   remaining milestones are granted in one pass, with a single summary
   toast.

### 6e. Global selection

1. Two servers at once, or restart the server after a day boundary →
   the pool id must be the **same** on both. Check the `PTD` debug log
   for `global pool active`.
2. With the DataStore unreachable, the log says
   `global store unreachable, deterministic fallback` and the pool is
   still identical across servers (hash-based).

### 6f. The global weekly pool (`DailyRewardsWeek`)

In Studio's command bar (server context):

```lua
local Week = require(ServerScriptService.Daily.DailyRewardsWeek)
print(Week.Current().WeekId, Week.Current().PoolId, Week.Current().Source)
```

Expect something like `W002994  Pool_B  global`.

1. Call `Current()` twice → identical results, and the second call does
   **not** hit the DataStore (the cache short-circuits).
2. Restart the server mid-week → the **same** `PoolId` comes back,
   because the DataStore committed it.
3. Call `Current(os.time() + 604800)` → a **different** `WeekId`, and a
   `PoolId` that is **not** the previous week's (when more than one pool
   is configured).
4. With the DataStore unreachable (turn **off** *Enable Studio Access to
   API Services* and restart), `Current().Source` becomes
   `'local-fallback'` and the pool is the deterministic hash pick; the
   same week still yields the same pool on another server with API
   access off.
5. **The misconfiguration path:** temporarily comment out all pools in
   `Rewards.lua` → `Daily.WeeklyPools` and restart →
   `Current().PoolId == ''` and `Current().Source == 'misconfigured'`.
   The Output window shows the warning **once**, not once per call.
   **Trap:** the misconfiguration is cached for the whole week. Fix the
   catalog and the module stays broken until the week rolls over — call
   `DailyRewardsWeek._TestReset()` to clear it.

---

## 7. Production checklist

- [ ] Both DataStore names renamed to your game's namespace.
- [ ] `DailyRewardsWeek.lua` is at `ServerScriptService/Daily/` — a
      direct sibling of `DailyRewardsService.lua`. The `script.Parent`
      require fails otherwise.
- [ ] The `Rewards.Daily.WeeklyPools` catalog is authored with at least
      one pool.
- [ ] The weekly rollover day is what you intended (Thursday 00:00 UTC
      by default).
- [ ] The code catalog authored for your game; the live catalog is not
      committed to a public repository.
- [ ] `ConfigValidator` registers all three reward domains.
- [ ] `createRemotes()` runs before the first `Init()`.
- [ ] `SetCodesService` is called before `DailyRewardsService.Init()`
      and `PlaytimeRewardsService.Init()`.
- [ ] `CodesService.OnPlayerReady` runs **after** base restore.
- [ ] `TryDeliverPending` is called whenever a base slot is freed.
- [ ] `GrantSkipAccess` is only reachable from a verified receipt.
- [ ] A boot with a config validation issue is a **hard error** in
      Studio and a **warning** in production — decide which you want
      and wire it accordingly.
