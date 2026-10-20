# Arena — MEMORY

Engineering notes for a future agent. Dense, factual, line-referenced.
Read `README.md` first for the shape; this file is the *why* and the *gotchas*.

---

## 1. Purpose in one line

Run a server-authoritative, continuous, multi-stage arena raid per player:
lock a team, fight stage after stage with HP carried across stages, settle
progressively at the end.

---

## 2. How it actually works, step by step

### 2.1 Boot

1. `bootstrap.server.lua:163-165` requires the three modules.
2. `bootstrap.server.lua:524-535` injects 11 dependencies via setters.
3. `bootstrap.server.lua:536` calls `ArenaService.Init()`.

`Init()` (`ArenaService.lua:3277`):
- Guarded by `started` (`:3278`) — idempotent.
- `ArenaConfig.ValidateLive()` → each issue is a `warn()`, never a throw (`:3282-3284`).
- Installs the four battle callbacks **only if `battleServiceRef` is set** (`:3285`):
  - `SetValidator` (`:3297`) — per-tick validity. Checks: player present, base
    still owned, battle folder still parented, `session.state == 'Active'`,
    `session.sessionId == battle.sessionId`, **`session.stageGeneration == battle.stageGeneration`**.
    Character death is **intentionally not checked** (`:3291-3296`) — a
    mid-raid avatar reset must not cancel the fight.
  - `SetOnBattleEnd` (`:3340`) → `ArenaService.CompleteBattle`.
  - `SetOnBattleCancel` (`:3345`) → `ArenaService.CancelBattleSilent`.
  - `SetEventSink` (`:3355`) → `ArenaHit` events go to **all** clients via
    `FireAllClients`; every other event is owner-targeted via `FireClient`.
- Wires `ArenaAction` remote (`:3376-3389`). The `assert` and the `Connect`
  are deliberately **two separate statements** — the source comments that
  fusing them calls `assert`'s boolean return as a function and breaks all
  Arena actions (`:3379-3384`). This is a real bug class in this codebase.
- Late-join self-heal: wires the Adventurer prompt on every already-occupied
  base (`:3395-3403`).

### 2.2 Starting a raid

Entry: `ArenaService.handleAction` (`:3239`) on the `ArenaAction` remote.
Only three actions exist: `'Open'`, `'Start'` / `'StartRaid'`, `'Cancel'`.
Anything else → `warn` (`:3267`).

`StartArena(player, option)` (`:1251`):
1. `validateStart(player, nil)` — order is player → services → base →
   session → carry/steal → team. **No level gate** (`:876-881`).
   `ValidateStart` (`:938`) is the public wrapper.
2. `battleServiceRef` must be set → else `'service-not-ready'` (`:1263`).
3. `resolveRestartStart` (`:1219`) resolves the option into
   `{ startLevel, price }`:
   - `Buy3` → free, stage 1.
   - `Buy1` → `RestartWarmupLevel(last)` = `max(1, floor(last/2))`, price `'25000'`.
   - `Buy2` → `RestartDirectLevel(last)` = `max(1, floor(last))`, price `'150000'`.
   `last` is the SAVED `LastReached`. The client never sends a level or price.
4. Price is charged atomically via `economyServiceRef.TrySpendMoney` with
   `TransactionReason.ArenaRestart` **before the session exists**.
5. Team is resolved from **arena slots** (`ResolveArenaTeam`, `:601`), trimmed
   to `MaxTeamSize` (3) by ascending `ArenaIndex`, and snapshotted immutably
   into `session.team`.
6. `sessionId` = `nextSessionId` (monotonic, `:125`).
7. `stageGeneration` starts at 1. `arenaLevel` = the resolved start level.
8. `startStageBattle(session, base)` (`:1081`).

### 2.3 The combat engine

`ArenaBattleService` (`ArenaBattleService.lua`).

- **One** `RunService.Heartbeat` connection for the whole server
  (`ensureScheduler`, cadence `ArenaFeel.Combat.TickInterval` = 0.25s).
  `TickAll(now)` (`:895`) walks the registry and calls `TickBattle`.
- `TickBattle` (`:618`):
  - Gates on `battle.state == 'Active'` and `now >= battle.nextTurnAt`.
  - `side = battle.turnSide == 'Enemy' and 'Enemy' or 'Player'` — **Player
    opens**; turns strictly alternate Player → Enemy → Player.
  - `nextTurnAttacker` (`:552`): sorts the side's combatants by
    `PositionIndex`, then walks forward from `battle.turnCursor[side]`
    (round-robin), skipping anyone with `Alive ~= true` or `CurrentHealth <= 0`.
    If nobody on the side is standing, the battle terminates — the wiped
    side can never act again (`:631-645`).
  - `PickTarget` (`:467`): among living foes, prefer the one whose
    `PositionIndex` equals the attacker's; otherwise the **first** living
    foe in table order (fallback).
  - Damage: `target.CurrentHealth = max(0, healthBefore - damage)`.
    `attacker.Damage` is sanitized (`not a number` / NaN / negative → 0).
  - **Damage ledger** (`:675-704`): only for `attacker.Team == 'Player'` and
    only when `attacker.SourceAnimalId` is a string. Contribution is
    `min(damage, healthBefore)` — **overkill never inflates a share**
    (10 HP left + 25 attack = 10 contribution). Keyed by `SourceAnimalId`
    (the persistent `UniqueId`), never `DefId`, so duplicate species stay
    individually trackable. The ledger only grows — dead animals keep what
    they earned while alive.
  - `attacker.NextAttackAt = now + (battle.cooldown or FALLBACK_COOLDOWN)`
    (`:707`) — this is a **diagnostic "last acted" stamp only**. Turn gating
    is owned by `nextTurnAt` / `TURN_INTERVAL`.
  - Sound index: a deterministic `1 → 2 → 3 → 1` cycle, advanced
    authoritatively here (`:712-717`) so the impact thread and every
    observer agree.
  - `attackSequence` is a monotonic counter on the battle.
  - `impactPosition` = `computeContactPoint(attacker, target)` — the target's
    **canonical body center** (its `HomeCFrame` position, never a live
    pivot). The previous revision offset outward by the body radius, which
    for small animals landed *outside* the part.
- Attack animation index comes from `_nextAnimIndex(battle)` — a
  **deterministic LCG PRNG seeded per battle**. It is not `Random.new()`.

### 2.4 Stage win → advance

`ArenaService.CompleteBattle` (`:2820`):

Guards, in order (each returns `{ success = false, error = <code> }`):
1. `invalid-args` — non-number ids (`:2826`).
2. `stale-session` — no session, or `session.sessionId ~= sessionId` (`:2830`).
3. `stale-stage` — `session.stageGeneration ~= stageGen` (`:2845`).
   `nil` matches only `nil` (gen-less legacy/test sessions).
4. `already-settled` — `session.state ~= 'Active'` (`:2854`).
5. `already-settled` — `session.settledStages[stage] == true` (`:2866`).

Then, **before any reward/advance decision** (`:2876-2885`):
- `session.state = 'Completing'`; `session.settledStages[stage] = true`.
- `snapshotRaidHP(session)` — freezes ending HP into the run.
- `carryBattleDamage(session)` — freezes the damage ledger into the run.
- `carryKeepsakes(session)` — captures survivors' combat models + drains
  death-time captures. **Must** run before any cleanup.

Win path (`:2886`):
- `accumulateStageReward(session, stage)` (`:1771`) — adds to
  `session.rewardAccum = { cash, xp }`. **No payout, no XP grant, no toast
  mid-raid.** The accumulator is the only thing that moves.
  - Idempotent via `session.rewardedStages[stage]`.
  - `xp = levelDef.Rewards.ArenaXP`.
  - Cash: first-clear or repeat, chosen by `session.firstClearCursor` — the
    cursor advances only when `stage == cursor`, reproducing the
    `RecordLevelWin` chain without touching persistence mid-raid (`:1798-1803`).
- `FunnelService.IsArenaMilestone(stage)` → funnel `StageProgressed`
  (milestones only: 1/5/10/25/50 — every stage win would be noise).
- If `stage >= session.maxLevel` → `terminateRaid(..., { RaidComplete = true })`.
- **Advance guard** (`:2923-2938`): count `session.raidAlive` survivors.
  The engine resolves the attacker's kill first, so a *mutual wipe reports
  won*. If nobody is standing, the raid ends **FAILED** (not complete) with
  `Reason = 'all-dead'` — but the accumulator (including the just-cleared
  stage) still settles progressively.
- Otherwise, continuous advance (`:2940-2978`):
  1. `cleanupBattleModels(session)` — old stage models destroyed now
     (mid-raid advance is immediate; only terminals get the 1.2s window).
  2. `session.stageGeneration += 1`.
  3. `session.arenaLevel = stage + 1`.
  4. `session.state = 'Transitioning'`.
  5. Re-resolve the base. If gone → `terminateRaid(..., Reason = 'no-base')`.
  6. `startStageBattle(session, base)`. If it fails →
     `terminateRaid(..., Reason = 'transition-failed')`.
  7. `PushState(player)`.

Loss path (`:2980-3002`): snapshot HP + damage + keepsakes again (the first
snapshot is taken pre-decision, this one is after) and
`terminateRaid(userId, session, { RaidComplete = false, Stage = stage })`.
**No `RaidFailed` warning is fired** — a wipe is a normal Arena completion
for progression purposes. The `RaidFailed` catalog entry is retained for
genuine setup/exploit aborts only.

### 2.5 Termination and settlement

`terminateRaid` (`:2261`) → `settleRaidReward` (`:1860`).

`settleRaidReward(userId, session, completed, suppressToast?)`:
1. **Idempotent**: `session.rewardSettled == true` → `{ ok = false, error = 'already-settled' }` (`:1866`).
2. `session.rewardSettled = true` — the flag is set **before** any I/O.
3. `totalCash` / `totalXP` from `session.rewardAccum`.
4. If `totalCash == '0' and totalXP <= 0` → `{ ok = true, paid = false, cash = '0', xp = 0 }`
   — **no transaction, no toast** (`:1901-1908`).
5. **History first**: one `RecordLevelWin(userId, stage)` per cleared stage,
   **in ascending order** (`:1916-1927`), so `Wins` and `HighestCompleted`
   reflect the settled run through the single authority.
6. **ONE economy transaction for the whole raid** (`:1928-1980`):
   - `BigNumber.sanitize(totalCash)`; if nil or `'0'` → the grant is
     **skipped** with a `warn` (`:1937-1944`). No retry.
   - `economyServiceRef.AddMoney(userId, saneCash, 'ArenaReward', { ApplyMultiplier = false })`.
     `ApplyMultiplier = false` — the arena payout is **not** scaled by the
     player's money multiplier.
   - On failure: `warn` — "settled once, no retry" (`:1954-1960`).
   - Canonical money sync follows (`CashCollected` + state push).
7. XP: `AddArenaXP` for the **player's** arena XP track.
8. **Animal XP split** (`:2417-2500`):
   - `mult = ArenaConfig.AnimalXPMultiplier()` (= 100), sanitized to 0 if
     not a finite number.
   - `pool = math.floor(totalXP * mult)` — **one total split N ways**, not
     N copies.
   - If `totalDamage <= 0` → **equal split**, remainder to roster order
     (`:2456-2472`). Never silently loses the reward.
   - Otherwise → **largest-remainder distribution** so the awarded sum
     **always equals the pool** (`:2450-2452`).
   - Requires `animalServiceRef.AddXP`.
9. `buildResultAnimals` (`:2056`) builds the client result rows, capped at
   `RESULT_CARD_CAP = ArenaConfig.ResultCardCap` (= 6, `:2054`).
10. `pushResult(player, 'RaidEnd', true, nil, {...})` (`:2757`).
11. `PushState(player)`.
12. `TutorialSignals.Fire('ArenaEnded', { UserId = userId })` (`:2772`).
13. Funnel + `PlayerLogger.LogMilestone` **only on `RaidComplete == true`**
    (`:2777-2785`).
14. **Keepsake retirement**: `task.delay(60, ClearSessionKeepsakes(sessionId))`
    (`:2799`). Note `KEEPSAKE_TTL_S = 180` in the battle service, but the
    arena retires them at **60s** — the shorter of the two wins in practice.

### 2.6 Retreat

`ArenaService.CancelArena(player)` (`:1528`):
- `session.state = 'Cleaned'` first.
- `settleRaidReward(userId, session, false, true)` — `suppressToast = true`.
  A retreat is **not** a completion, so there is no completion toast.
- `setRaidDeployment(session, false)` — the team returns to its arena stands.
- `_restoreAdv(userId)`.
- `cleanupBattleModels(session, TERMINAL_CLEANUP_DELAY)` — 1.2s window.
- `sessions[userId] = nil`.
- `lastRaid[userId] = { ..., Retreated = true }`.
- `pushResult(player, 'Cancel', true, nil, { RaidComplete = false, Stage, MaxStage })`.
- `TutorialSignals.Fire('ArenaCancelled', { UserId = userId })`.

### 2.7 Leave

`ArenaService.ForgetPlayer(userId)` (`:1652`): terminates the raid with
**no further rewards** (the settlement already happened or is skipped),
restores the Adv, drops the session.

### 2.8 Progression

`ArenaProgressionService` (`ArenaProgressionService.lua`).

- `NormalizeArena(data)` (`:51`): creates/repairs `data.Arena`. Returns
  `nil` for a non-table profile.
- `AddXPToData(arena, amount)` (`:104`): adds to `arena.XP`, then loops
  `XPRequired(arena.Level)` and levels up while the threshold is met.
  `XPRequired` returns `nil` at `playerLevel >= MAX_LEVEL`, so the loop
  terminates at the cap. Non-positive / NaN amount → `{ LevelsGained = 0, Level = arena.Level }`
  — **the XP is NOT added**.
- `GetArenaState` (`:176`): the snapshot for the menu.
- `RecordLevelWin(userId, arenaLevel)` (`:277`): `arena.Wins += 1`, updates
  `HighestCompleted`, returns `{ Wins, HighestCompleted, FirstClear }`.
  `HighestCompleted` advances **strictly sequentially** — only when
  `arenaLevel == arena.HighestCompleted + 1` (`:295`). A replay or a forged
  gap stage can never create a gap. `FirstClear` is `true` exactly on that
  advancing write.
- `RecordReachedLevel(userId, stage)` (`:326`): monotonic
  (`s > arena.LastReached` required, `:336`). Records the highest stage
  ever **reached** — this drives the paid-restart start stage.
- `GetLastReached` (`:310`), `ResetArena` (`:352`).

---

## 3. Exact public API surface

### `ReplicatedStorage.Config.World.Arena` (config)

```lua
Arena.MaxLevel(): number                      -- :1082  = #LEVELS (50)
Arena.MinTeamSize(): number                   -- :1086  = 1
Arena.MaxTeamSize(): number                   -- :1090  = 3
Arena.AnimalXPMultiplier(): number            -- :1094  = 100
Arena.AttackCooldown(): number                -- :1098  = 1.5
Arena.RestartWarmupPrice(): string            -- :1105  = '25000'
Arena.RestartDirectPrice(): string            -- :1109  = '150000'
Arena.RestartWarmupLevel(lastReached: any): number?   -- :1120  max(1, floor(last/2)); nil if last invalid
Arena.RestartDirectLevel(lastReached: any): number    -- :1130  max(1, floor(last)); 1 if last invalid
Arena.IsRestartAvailable(lastReached: any, warmupOnly: boolean?): boolean  -- :1142
Arena.GetAll(): { ArenaLevelDef }             -- :1156  the LEVELS array itself
Arena.FindLevel(level: number): ArenaLevelDef?-- :1160  nil for non-integer / not found
Arena.IsValidLevel(level: any): boolean       -- :1172
Arena.IsBossLevel(level: number): boolean     -- :1176
Arena.IsUnlocked(playerLevel: number, arenaLevel: number): boolean  -- :1191  TEST-ONLY
Arena.XPRequired(playerLevel: number): number?  -- :1210  floor(5 * 1.25^(L-1) + 0.5); nil for L<1 or L>=MAX_LEVEL
Arena.Dialogue(category: string): { string }   -- :1220  falls back to DIALOGUE.Greeting
Arena.ValidateList(levels: any, defProbe: ((string) -> any)?): { string }  -- :1235
Arena.ValidateLive(): { string }              -- :1308  requires Config.Creatures.Animals
Arena.ResultCardCap                          -- :1323  a FIELD, = 6 (not a function)
```

### `ReplicatedStorage.Config.World.ArenaFeel` (config)

```lua
ArenaFeel.Validate(): { string }              -- :334   the only export
```

### `ServerScriptService.Arena.ArenaService`

```lua
ArenaService.SetPlayerService(svc: any)       -- :132
ArenaService.SetBaseService(svc: any)         -- :136
ArenaService.SetAnimalService(svc: any)       -- :140
ArenaService.SetSlotService(svc: any)         -- :144
ArenaService.SetCarryRegistry(svc: any)       -- :148
ArenaService.SetStealService(svc: any)        -- :152
ArenaService.SetNotificationService(svc: any) -- :156
ArenaService.SetProgressionService(svc: any)  -- :160
ArenaService.SetEconomyService(svc: any)      -- :164
ArenaService.SetBattleService(svc: any)       -- :168
ArenaService.EnsureAdventurer(base: any): boolean  -- :407
ArenaService.ResolveTeam(userId: number): { [string]: any }        -- :531  TEST-ONLY
ArenaService.ResolveArenaTeam(userId: number): { [string]: any }   -- :601
ArenaService.ResolveArenaArea(base: any): { [string]: any }        -- :707
ArenaService.DebugArea(base: any)                                  -- :774
ArenaService.GetSession(userId: number): { [string]: any }?         -- :836
ArenaService.IsAnimalRaidLocked(uniqueId: string): boolean          -- :849
ArenaService.HasActiveRaid(userId: number): boolean                -- :868
ArenaService.ValidateStart(player: Player, _arenaLevel: any): { [string]: any }  -- :938
ArenaService.StartArena(player: Player, option: any): { [string]: any }          -- :1251
ArenaService.StartRaid(player: Player): { [string]: any }                        -- :1462
ArenaService.cleanupBattleModels(session: { [string]: any }?, delaySec: number?) -- :1480
ArenaService.CancelArena(player: Player): { [string]: any }                      -- :1528
ArenaService.CancelBattleSilent(userId: number, sessionId: number, stageGen: number?)  -- :1594
ArenaService.OpenArena(player: Player)                                           -- :1630
ArenaService.ForgetPlayer(userId: number)                                        -- :1652
ArenaService.CompleteBattle(userId: number, sessionId: number, won: boolean, stageGen: number?): { [string]: any }  -- :2820
ArenaService.BuildState(player: Player): { [string]: any }?                       -- :3053
ArenaService.PushState(player: Player, show: boolean?)                           -- :3228
ArenaService.Init()                                                              -- :3277
-- test seams
ArenaService._TestReset()                                                        -- :3407
ArenaService._TestResolveRestart(userId: number, option: any): { [string]: any }  -- :3417
ArenaService._TestInjectSession(userId: number, session: { [string]: any })      -- :3423
ArenaService._TestSetRaidDeployment(session: { [string]: any }, deployed: boolean)-- :3431
ArenaService._TestTerminateRaid(...)                                            -- :3442
ArenaService._TestBuildResultAnimals(...)                                       -- :3462
ArenaService._TestHideAdv(userId: number, base: any): boolean                    -- :395
ArenaService._TestRestoreAdv(userId: number): boolean                            -- :399
ArenaService._TestAdvHidden(userId: number): boolean                             -- :403
```

### `ServerScriptService.Arena.ArenaBattleService`

```lua
ArenaBattleService.SetValidator(fn: ((any) -> boolean)?)                       -- :116
ArenaBattleService.SetOnBattleEnd(fn: ((number, number, boolean, number?) -> ())?)  -- :120
ArenaBattleService.SetOnBattleCancel(fn: ((number, number, number?) -> ())?)   -- :124
ArenaBattleService.SetEventSink(fn: ((number, { [string]: any }) -> ())?)      -- :135
ArenaBattleService.SetAnimalService(svc: any)                                  -- :139
ArenaBattleService.BuildPlayerCombatant(member: any, positionIndex: number, now: number, cooldown: number, hpOverride: number?): (any?, string?)  -- :199
ArenaBattleService.BuildEnemyCombatant(enemyDef: any, positionIndex: number, now: number, cooldown: number): (any?, string?)  -- :290
ArenaBattleService.CreateBattle(userId: number, sessionId: number, arenaLevel: number, playerMembers: { any }, enemyDefs: { any }, cooldown: number, now: number, stageGeneration: number?, hpBySource: { [string]: number }?): (any?, string?)  -- :350
ArenaBattleService.GetBattle(userId: number): { [string]: any }?               -- :456
ArenaBattleService.PickTarget(battle: { [string]: any }, attacker: { [string]: any }): { [string]: any }?  -- :467
ArenaBattleService.TickBattle(battle: { [string]: any }, now: number): { [string]: any }  -- :618
ArenaBattleService.RegisterBattle(battle: { [string]: any }): boolean          -- :792
ArenaBattleService.UnregisterBattle(userId: number)                            -- :804
ArenaBattleService.TickAll(now: number)                                        -- :895
ArenaBattleService.ResolveBattlePositions(base: any, playerCount: number, enemyCount: number): { [string]: any }  -- :1014
ArenaBattleService.SpawnBattleModels(battle: { [string]: any }, base: any): { [string]: any }  -- :1219
ArenaBattleService.DestroyBattleModels(battle: { [string]: any })               -- :1427
ArenaBattleService.PresentAttack(battle: { [string]: any }, attack: { [string]: any }): number  -- :1815
ArenaBattleService.CaptureKeepsake(battle: { [string]: any }, combatant: { [string]: any }?, model: Model?)  -- :2063
ArenaBattleService.CaptureLiveKeepsakes(battle: { [string]: any })             -- :2120
ArenaBattleService.TakeKeepsakes(battle: { [string]: any }): { [string]: Model }-- :2135
ArenaBattleService.ClearSessionKeepsakes(sessionId: number)                    -- :2173
ArenaBattleService.PresentDeath(battle: { [string]: any }, combatantId: string, delaySec: number?)  -- :2200
ArenaBattleService._TestReset()                                                -- :2272
```

### `ServerScriptService.Arena.ArenaProgressionService`

```lua
ArenaProgressionService.SetPlayerService(svc: any)         -- :42
ArenaProgressionService.NormalizeArena(data: any): { [string]: any }?   -- :51
ArenaProgressionService.AddXPToData(arena: { [string]: any }, amount: number): { [string]: any }  -- :104
ArenaProgressionService.GetArenaLevel(playerOrUserId: any): number      -- :151
ArenaProgressionService.GetArenaXP(playerOrUserId: any): number         -- :163
ArenaProgressionService.GetArenaState(playerOrUserId: any): { [string]: any }  -- :176
ArenaProgressionService.GetHighestCompleted(playerOrUserId: any): number-- :205
ArenaProgressionService.IsUnlocked(playerOrUserId: any, arenaLevel: number): boolean  -- :226  NO PRODUCTION CALLER
ArenaProgressionService.AddArenaXP(userId: number, amount: number): { [string]: any }  -- :235
ArenaProgressionService.RecordWin(userId: number): number                -- :255  NO PRODUCTION CALLER
ArenaProgressionService.RecordLevelWin(userId: number, arenaLevel: number): { [string]: any }  -- :277
ArenaProgressionService.GetLastReached(playerOrUserId: any): number      -- :310
ArenaProgressionService.RecordReachedLevel(userId: number, stage: number): number  -- :326
ArenaProgressionService.ResetArena(userId: number): boolean              -- :352
ArenaProgressionService._TestReset()                                    -- :345
```

---

## 4. Invariants the code enforces

1. **One raid session per player.** `sessions[userId]`. A second start
   rejects with `'session-exists'` (the `validateStart` session check).
2. **`(sessionId, stageGeneration)` is the staleness token.** A callback
   whose generation does not match the session's current generation is
   rejected with `stale-stage` and changes nothing — no accumulator write,
   no state write, no reward.
3. **A stage settles at most once.** `session.settledStages[stage]` plus
   `session.state` guard. A duplicate battle-end cannot double-pay.
4. **A raid settles at most once.** `session.rewardSettled`.
5. **The team is immutable.** `session.team` is a snapshot taken at start.
   Later edits to the player's animals do not change the running raid.
6. **Raid HP never touches persistent animals.** `session.raidHP` /
   `session.raidAlive` are run state. There is no code path that writes
   battle HP back into the animal record.
7. **Dead stays dead.** No heal, no revive. `raidAlive` is monotone within
   a run.
8. **Cash is a BigNumber decimal string, always.** Never a Lua number.
9. **The server never trusts the client.** `ArenaAction` carries only
   `Action` and `Option`. Loadout, stage, HP, and rewards are all
   re-resolved server-side.
10. **Rewards are paid in exactly one economy transaction per raid.**
11. **The animal XP pool always sums exactly.** Largest-remainder
    distribution (or an exact equal split) — no dust is lost.
12. **Overkill does not inflate a damage share.** Contribution is clamped
    to the target's remaining HP.
13. **The client receives the ACTUAL combat models.** Keepsakes are
    pristine clones of the real combat models, never templates.
14. **`AddMoney` for arena rewards uses `ApplyMultiplier = false`.**
15. **Character death is not a battle-invalidating condition.** The raid
    runs to its real terminal state regardless of the avatar's health.

---

## 5. Failure and edge-case behaviour

| Situation | Behaviour |
|---|---|
| `StartArena` with no base | `validateStart` rejects → `{ success = false, error = ... }`. No session is created. |
| `StartArena` with an empty team | Rejected — `team.count < MinTeamSize()` → `'no-team'`. |
| `StartArena` with more than 3 in the arena slots | The team is **trimmed** to the first 3 by ascending `ArenaIndex`, with a loud warning. It is never silently reordered. |
| `StartArena` with `battleServiceRef` unset | `{ success = false, error = 'service-not-ready' }` (`:1263`). |
| `StartArena` with an unaffordable paid restart | The economy charge fails → the start is rejected **before** the session is created. |
| `StartArena` with an unknown `Option` | Treated as the free path (or rejected) — the client cannot buy a cheaper or a higher-tier start by tampering. |
| Battle with no living attacker on the acting side | The battle terminates: the wiped side loses (`:634-645`). |
| Battle with no living target | The attacking side wins (`:648-662`). |
| Mutually lethal final exchange | The engine resolves the attacker's kill first, so it reports **won**. The `standing < 1` guard then converts it to a FAILED raid with `Reason = 'all-dead'`, but the cleared stage still settles. |
| `CompleteBattle` with a stale session or generation | `{ success = false, error = 'stale-session' }` / `'stale-stage'`. **Nothing changes.** |
| `CompleteBattle` for an already-settled stage | `{ success = false, error = 'already-settled' }`. |
| Validator trip (player left, base lost, models destroyed) | `CancelBattleSilent` — the session is dropped silently. **No reward, no stage settlement, no toast.** |
| `CancelBattleSilent` with a mismatched generation | Silent no-op (`:1602`). |
| Base disappears mid-raid | `terminateRaid(..., Reason = 'no-base')`. Earned rewards are kept; no further stages. |
| `startStageBattle` fails on advance | `terminateRaid(..., Reason = 'transition-failed')`. Rewards already accumulated are kept. |
| Nothing was cleared (wiped on stage 1) | `{ ok = true, paid = false, cash = '0', xp = 0 }` — no transaction, **silent**, no toast. |
| `BigNumber.sanitize` rejects the accumulated cash | The grant is **skipped** with a `warn`. The settlement is still marked done — **no retry**. |
| `AddMoney` fails | `warn` — "settled once, no retry". The settlement is still marked done. |
| `totalDamage == 0` at the terminal | Equal split of the pool; the remainder goes to roster order. The reward is never silently lost. |
| `terminalRoster` is empty | The pool is not awarded (the guard is `pool > 0 and #terminalRoster > 0`, `:2449`). |
| `animalServiceRef` or `.AddXP` is unset | The animal XP award is skipped entirely. |
| `progressionServiceRef` unset | `BuildState` falls back to `{ Level = 1, XP = 0, XPRequired = 100, Wins = 0 }` (`:3058`). The XP curve then looks wrong but nothing throws. |
| `baseServiceRef` unset | `ResolveArenaTeam` / `ResolveTeam` return `{ members = {}, count = 0 }`. `ResolveArenaArea` returns `{ ready = false, center = nil, missing = {...} }`. |
| `ArenaConfig.ValidateLive()` finds problems | Each is a `warn`. **The system still boots.** |
| `ArenaAction` remote missing | `warn` — "Action remote wiring failed". The Arena is inert but the server does not crash. |
| A player presses the prompt with no authored Adventurer | A temporary brick NPC is created (marked `ArenaTemporary = true`) with a 5s START-button self-heal backstop. It is reused across assignments and never duplicated. |
| `CancelArena` with no session | `{ success = false, error = 'no-session' }`. |
| `CancelArena` with a non-live player | `{ success = false, error = 'invalid-player' }`. |
| `ForgetPlayer` for a player with no session | Silent no-op. |
| `ResolveArenaArea` with a missing `Arena` folder | `{ ready = false, center = nil, missing = { '<path>/Arena (folder)' } }`. |
| `PresentAttack` with no live models | Returns `0`. No throw. |

---

## 6. Gotchas that would bite you

1. **`ArenaFeel.Combat.EasingStyle` is dead.** `tweenModelTo` hardcodes
   `Enum.EasingStyle.Quad` (`ArenaBattleService.lua:1514`). Nothing reads
   the config field. Setting it to `'Sine'` is a no-op.
2. **`ArenaConfig.AttackCooldown` does not control attack cadence.** The
   real pacing is `ArenaFeel.Combat.TurnInterval` (1.1s) via `TURN_INTERVAL`
   (`ArenaBattleService.lua:524`). `AttackCooldown` only stamps the
   diagnostic `NextAttackAt` (`:707`). Changing it alone does not change
   how fast fights feel.
3. **`ArenaConfig.MAX_LEVEL` is reassigned.** `Arena.lua:72` declares
   `MAX_LEVEL = 10`; `Arena.lua:1057` re-assigns it to `#LEVELS` (50). The
   literal 10 is dead code. Never hardcode a cap.
4. **`ArenaFeel.DeathFade.Steps` has a stale comment** — the comment says
   "CURRENT: 5", the value is `3`.
5. **Three exported functions have no production caller:**
   `ArenaConfig.IsUnlocked` (test-only), `ArenaProgressionService.IsUnlocked`
   (never called), `ArenaProgressionService.RecordWin` (test-only — the live
   path is `RecordLevelWin`), and `ArenaService.ResolveTeam` (test-only —
   the live path is `ResolveArenaTeam`). **There is no level gate on
   starting a raid.**
6. **The system has no client code.** The Arena menu, hit presentation,
   camera impacts, and result card are in the **ClientPresentation**
   system; the screen coordinator is `ReplicatedStorage.Utility.ArenaUIState`
   in the Shared folder. Copying only `Systems/Arena/` gives you a server
   that fights correctly and renders nothing.
7. **All telemetry is dormant.** `Debug.Log` / `Debug.Warn` are gated on
   `Config.Systems.Debug.ServerDebug = false` — every warning this system
   emits, including genuine config errors, is invisible by default.
   Turn it on to debug.
8. **`ArenaAction` remote wiring: keep the `assert` and the `Connect`
   separate.** Fusing them (`assert(x)(remote).OnServerEvent:Connect(...)`)
   calls `assert`'s boolean return as a function and breaks **all** Arena
   actions. The source calls this out explicitly (`:3379-3384`).
9. **Character death does not cancel a raid.** By design (`:3291-3296`).
   Don't "fix" it.
10. **A mutual wipe reports `won` from the engine.** The `standing < 1`
    guard is what converts it to a FAILED raid. If you reorder those, a
    wipe will pay as a full clear.
11. **`PresentAttack`'s returned delay is computed from
    `spec.impactOffset`, but the visual contact actually happens after the
    full `spec.dur` flourish.** The number is a scheduling hint, not the
    real contact time.
12. **`AddXPToData` silently drops a non-positive amount** — it returns
    `{ LevelsGained = 0, Level = arena.Level }` *without* adding the XP.
13. **The first-clear cursor is a session field**, not a profile field
    (`session.firstClearCursor`). A raid that starts at stage 20 via a paid
    restart has cursor 1, so stage 20 pays `RepeatCash`, not `FirstClearCash`.
14. **Keepsake retirement is 60s** in `ArenaService` (`:2799`), while
    `KEEPSAKE_TTL_S = 180` in the battle service. The 60s wins.
15. **`PresentAttack` needs the attack animation index to be in
    `1..5`** (`ATTACK_ANIMATION_COUNT = 5`, `ArenaBattleService.lua:525`);
    out-of-range indices are clamped to 1 (`:1829-1831`). The index is
    broadcast to clients, so the **order** of `ArenaFeel.AttackAnims` is a
    client contract.
16. **The `assert` on the `ArenaAction` remote is inside a `pcall`** —
    a missing remote is a `warn`, not a crash.
17. **`ResolveArenaTeam` reads `base.arenaSlots`**, a field on the base
    record — not the ordinary `SnapshotBaseSlots` the base slots use.
    Arena slots live in the `1000 + k` namespace
    (`SlotType.ArenaSlotIndexBase = 1000`).
18. **The `LivePlayer` check is the only player-liveness gate** on the
    public entry points. `CompleteBattle` and `CancelBattleSilent` do not
    call it — they validate via the session token instead.

---

## 7. What to change to reuse it

| To change | Edit | Note |
|---|---|---|
| The stages | `Arena.lua` `LEVELS` array | Keep `Level` contiguous from 1. `MaxLevel` follows automatically. |
| The XP curve | `Arena.lua:1210` `XPRequired` | Do **not** linearize without re-solving the settle ratios — the source warns that flat 100-per-level "collapsed against exponential settles (one full clear capped the whole track)". |
| The animal XP multiplier | `Arena.lua:98` `ANIMAL_XP_MULTIPLIER` | Applied once, at the arena layer. Do not also scale the accumulator. |
| The team cap | `Arena.lua:88` `MAX_TEAM_SIZE` | **Also** re-author `Arena/PlayerSpawns/Position1..3` — the arena authors exactly three. Otherwise the battle fails with `positions-not-ready`. |
| The prices | `Arena.lua:117-118` | BigNumber strings. Charged via `EconomyService.TrySpendMoney`. |
| The combat feel | `ArenaFeel.lua` `Combat`, `AttackAnims` | The five attack-anim **order** is a client contract; the keyframes themselves are code-owned in `ArenaBattleService` (`animLunge` / `animHopSlam` / `animSpin` / `animSideSwing` / `animBounceCharge`). |
| The prompt | `Config/World/Prompts.lua` `Prompts.Arena` | Lives in the **Carry** system's config. |
| The battle area | The base folder's `Arena/` sub-folder | `PlayerSpawns/Position<N>`, `EnemySpawns/Position<N>`. |
| The entry point | The base folder's `Adventurer` (or `Adv`) | Without one, a temporary brick NPC is used. |
| The result cap | `Arena.lua:1323` `ResultCardCap` | One value, read by both the server (`RESULT_CARD_CAP`) and the client. |
| The injected services | The ten `Set*Service` calls in `bootstrap` | There is no `require` between the Arena and the other services — that is what keeps the graph acyclic. |

---

## Related

- [README.md](README.md) — overview, entry points, limitations.
- [API.md](API.md) — every public function, grouped by module.
- [Dependencies.md](Dependencies.md) — require paths, remotes, profile fields, assets, init order.
- [Setup.md](Setup.md) — install into a new Rojo project.
- [Config.lua](Config.lua) — the consolidated tunable mirror.
