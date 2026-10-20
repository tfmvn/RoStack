# Arena — API

Every **public** function of every module in the system, grouped by module.
Line numbers refer to the files under `Source/`.

**Failure-mode convention:** every function in this system is
**non-throwing**. Validation failures return a sentinel value (`nil`, `0`,
`false`, or an `{ error = '...' }` table) — they never `error()`. Internal
calls to other services are wrapped in `pcall`, so a misbehaving dependency
degrades rather than crashes.

---

## `ReplicatedStorage.Config.World.Arena`

The stage catalog and the gameplay tunables.

### Read-only fields

| Field | Type | Value | Notes |
|---|---|---|---|
| `Arena.ResultCardCap` | number | `6` | A **field**, not a function (`Arena.lua:1323`). The server truncates the result rows to it and the client renders at most that many. |

### `Arena.MaxLevel(): number` — `Arena.lua:1082`

The number of stages in the catalog. Derived as `#LEVELS` (50) after the
catalog is built; the `MAX_LEVEL = 10` literal at `Arena.lua:72` is
reassigned at `:1057` and is dead.

- **Parameters:** none.
- **Returns:** the stage count.
- **Failure modes:** none.

### `Arena.MinTeamSize(): number` — `Arena.lua:1086`

Minimum occupied arena slots required to start an expedition. Default `1`.

- **Returns:** the minimum team size.
- **Failure modes:** none.

### `Arena.MaxTeamSize(): number` — `Arena.lua:1090`

Maximum player combatants per battle. Default `3`. **Not a tuning knob** —
the arena authors exactly three `PlayerSpawns` markers.

- **Returns:** the maximum team size.
- **Failure modes:** none.

### `Arena.AnimalXPMultiplier(): number` — `Arena.lua:1094`

Per-animal XP multiplier applied to the settled raid XP **before** the split
across the team. Default `100`.

- **Returns:** the multiplier.
- **Failure modes:** none. (The caller sanitizes it: a non-number / NaN /
  infinite value is coerced to `0` at `ArenaService.lua:2419`.)

### `Arena.AttackCooldown(): number` — `Arena.lua:1098`

Base attack cooldown in seconds. Default `1.5`.

- **Returns:** the cooldown.
- **Failure modes:** none.
- **Note:** this does **not** set the attack cadence — see
  [Known Limitations](README.md#known-limitations).

### `Arena.RestartWarmupPrice(): string` — `Arena.lua:1105`

The `Buy1` warmup restart price. Default `'25000'` — a BigNumber decimal
**string**.

- **Returns:** the price string.
- **Failure modes:** none.

### `Arena.RestartDirectPrice(): string` — `Arena.lua:1109`

The `Buy2` direct restart price. Default `'150000'` — a BigNumber decimal
**string**.

- **Returns:** the price string.
- **Failure modes:** none.

### `Arena.RestartWarmupLevel(lastReached: any): number?` — `Arena.lua:1120`

Resolves the `Buy1` warmup start stage: `max(1, floor(lastReached / 2))`.

- **Parameters:** `lastReached` — the saved highest stage reached. Anything
  `tonumber` can coerce to an integer `>= 1`.
- **Returns:** the start stage, or `nil` when there is no valid restart
  progress.
- **Failure modes:** returns `nil` for `nil`, a non-number, a non-integer,
  or a value `< 1`. Callers must also check `Arena.IsRestartAvailable`.

### `Arena.RestartDirectLevel(lastReached: any): number` — `Arena.lua:1130`

Resolves the `Buy2` direct start stage: `max(1, floor(lastReached))`.

- **Parameters:** `lastReached` — the saved highest stage reached.
- **Returns:** the start stage. **Never `nil`** — an invalid input returns
  `1`.
- **Failure modes:** none; invalid input degrades to stage `1`.

### `Arena.IsRestartAvailable(lastReached: any, warmupOnly: boolean?): boolean` — `Arena.lua:1142`

Whether a paid restart option is currently meaningful.

- **Parameters:**
  - `lastReached` — the saved highest stage reached.
  - `warmupOnly` — when `true`, checks the `Buy1` warmup path only.
- **Returns:** `true` when the option is available.
- **Failure modes:** returns `false` (never throws) when `lastReached` is
  `nil`, non-integer, `< 2`, or `> MAX_LEVEL`; and for the warmup path when
  the resolved warmup stage would be `<= 1` (i.e. `LastReached < 4`).

### `Arena.GetAll(): { ArenaLevelDef }` — `Arena.lua:1156`

The whole stage catalog.

- **Returns:** the `LEVELS` array **itself** (not a copy). Mutating it
  mutates the catalog. Treat it as read-only.
- **Failure modes:** none.

### `Arena.FindLevel(level: number): ArenaLevelDef?` — `Arena.lua:1160`

Finds one catalog entry by level.

- **Parameters:** `level` — the stage number.
- **Returns:** the entry, or `nil`.
- **Failure modes:** returns `nil` for a non-number, a non-integer, or a
  level that is not in the catalog.

### `Arena.IsValidLevel(level: any): boolean` — `Arena.lua:1172`

Whether a level exists in the catalog. A thin wrapper over `FindLevel`.

- **Returns:** `true` / `false`.
- **Failure modes:** none — returns `false` for any invalid input.

### `Arena.IsBossLevel(level: number): boolean` — `Arena.lua:1176`

Whether a stage is a boss stage.

- **Parameters:** `level` — the stage number.
- **Returns:** `true` when `level % 10 == 0` (10/20/30/40/50).
- **Failure modes:** returns `false` for a non-number, a non-integer, or a
  level `< 1`.

### `Arena.IsUnlocked(playerLevel: number, arenaLevel: number): boolean` — `Arena.lua:1191`

Legacy display-only helper: `playerLevel >= arenaLevel`.

- **Parameters:** `playerLevel` — the player's arena XP level; `arenaLevel` —
  the stage.
- **Returns:** `true` / `false`.
- **Failure modes:** returns `false` for a non-number argument or an invalid
  arena level.
- **Note:** **no production caller.** Only `Tests/Arena.spec.lua:52-56`.
  There is no level gate on starting a raid.

### `Arena.XPRequired(playerLevel: number): number?` — `Arena.lua:1210`

Arena XP required to advance from `playerLevel` to the next.
`floor(5 * 1.25 ^ (playerLevel - 1) + 0.5)` (round half up).

- **Parameters:** `playerLevel` — the current arena level.
- **Returns:** the XP threshold, or `nil` at the cap.
- **Failure modes:** returns `nil` for a non-number, a non-integer, a level
  `< 1`, or a level `>= MAX_LEVEL`.

### `Arena.Dialogue(category: string): { string }` — `Arena.lua:1220`

The greeting / normal / high / boss dialogue lines for a category.

- **Parameters:** `category` — `'Greeting'`, `'Normal'`, `'High'`, or `'Boss'`.
- **Returns:** the line array.
- **Failure modes:** falls back to `DIALOGUE.Greeting` for a non-string or
  an unknown category. **Never returns `nil`.**

### `Arena.ValidateList(levels: any, defProbe: ((string) -> any)?): { string }` — `Arena.lua:1235`

Validates a candidate catalog without touching the live one.

- **Parameters:**
  - `levels` — the candidate `LEVELS` array.
  - `defProbe` — optional callback that returns a truthy value when a
    `DefinitionId` resolves. When omitted, definition ids are not probed.
- **Returns:** a list of issue strings. **Empty means valid.**
- **Failure modes:** returns `{ 'catalog is not a table' }` for a non-table.
  Never throws.

### `Arena.ValidateLive(): { string }` — `Arena.lua:1308`

Validates the live catalog **and** every enemy `DefinitionId` against the
live animal definition catalog.

- **Parameters:** none.
- **Returns:** a list of issue strings. Empty means valid.
- **Failure modes:** never throws. `ArenaService.Init()` prints each issue
  as a `warn` and **continues to boot** (`:3282-3284`).
- **Side effect:** lazily `require`s
  `ReplicatedStorage.Config.Creatures.Animals` (`:1309`). This is the
  Arena system's only dependency on the Animals system's config.

---

## `ReplicatedStorage.Config.World.ArenaFeel`

### `ArenaFeel.Validate(): { string }` — `ArenaFeel.lua:334`

Validates the presentation tunables.

- **Parameters:** none.
- **Returns:** a list of issue strings. Empty means valid.
- **Failure modes:** never throws. Checks ranges (durations positive,
  transparencies in `0..1`, `FlashDuration < Duration`, `MaxCleanup >=
  MinCleanup`, `MaxRange >= FullRange`, `Steps >= 1`, and that
  `AttackAnims` has exactly 5 entries).

> This is the module's **only** export. Everything else is a data field.

---

## `ServerScriptService.Arena.ArenaService`

### Dependency injection

All ten setters take `svc: any` and simply assign a module-level reference.
They never validate the reference, never throw, and can be called in any
order — but `Init()` must come after all of them.

| Function | Line | Injected service |
|---|---|---|
| `ArenaService.SetPlayerService(svc: any)` | `:132` | `PlayerService` — profile access. |
| `ArenaService.SetBaseService(svc: any)` | `:136` | `BaseService` — base lookup, base folder. |
| `ArenaService.SetAnimalService(svc: any)` | `:140` | `AnimalService` — animal records and `AddXP`. |
| `ArenaService.SetSlotService(svc: any)` | `:144` | `SlotService` — base slot snapshots. |
| `ArenaService.SetCarryRegistry(svc: any)` | `:148` | `CarryRegistry` — carry-state check at start. |
| `ArenaService.SetStealService(svc: any)` | `:152` | `StealService` — steal-state check at start. |
| `ArenaService.SetNotificationService(svc: any)` | `:156` | `NotificationService` — the toast channel. |
| `ArenaService.SetProgressionService(svc: any)` | `:160` | `ArenaProgressionService` — arena XP / wins / highest. |
| `ArenaService.SetEconomyService(svc: any)` | `:164` | `EconomyService` — `TrySpendMoney` / `AddMoney`. |
| `ArenaService.SetBattleService(svc: any)` | `:168` | `ArenaBattleService` — the combat engine. |

- **Returns:** nothing.
- **Failure modes:** none.

### `ArenaService.Init()` — `ArenaService.lua:3277`

Bootstraps the Arena: validates the config, installs the four battle
callbacks, wires the `ArenaAction` remote, and late-join self-heals the
Adventurer prompt on every occupied base.

- **Parameters:** none.
- **Returns:** nothing.
- **Failure modes:**
  - Idempotent — a second call returns immediately (`:3278`).
  - Config issues are `warn`ed, never fatal.
  - The four battle callbacks are installed **only if `battleServiceRef` is
    set** — without it, the battle engine never reports back and no raid
    can advance.
  - A missing `ArenaAction` remote is a `warn`
    ("Action remote wiring failed"), **not** a crash — the `assert` is
    inside a `pcall` (`:3385`).
  - Never throws.

### `ArenaService.EnsureAdventurer(base: any): boolean` — `ArenaService.lua:407`

Resolves the base's Adventurer host and installs the `ProximityPrompt`.

- **Parameters:** `base` — the base record (a table with a `folder` field).
- **Returns:** `true` when a prompt is wired, `false` otherwise.
- **Failure modes:**
  - `false` for a base with no `folder` (`:408`).
  - `false` when the folder scan throws (`:417`).
  - `false` when no prompt could be created.
  - Never throws.
- **Notes:** the host priority is authored `Adventurer` → authored `Adv` →
  a temporary code-built NPC marked `ArenaTemporary = true`. **Idempotent** —
  repeated calls reuse the same instance and never duplicate it.

### `ArenaService.ResolveTeam(userId: number): { [string]: any }` — `ArenaService.lua:531`

Resolves the team from the base's **ordinary** slots.

- **Parameters:** `userId` — the player.
- **Returns:** `{ members = {...}, count = number }`.
- **Failure modes:** returns `{ members = {}, count = 0 }` when the user id
  is not a number, when `baseServiceRef` / `slotServiceRef` /
  `animalServiceRef` is unset, or when the base lookup fails. Never throws.
- **Note:** **test-only.** The live path is `ResolveArenaTeam`.

### `ArenaService.ResolveArenaTeam(userId: number): { [string]: any }` — `ArenaService.lua:601`

Resolves the team from the base's **arena slots** — the live team resolver.

- **Parameters:** `userId` — the player.
- **Returns:** `{ members = {...}, count = number }`. Each member is
  `{ UniqueId, DefinitionId, DisplayName, Rarity, Level, Trait, Mutations, OwnerUserId, ArenaSlotId, ArenaIndex }`.
- **Failure modes:** returns `{ members = {}, count = 0 }` for a non-number
  user id, an unset service, a missing base, or a base with no
  `arenaSlots`. Never throws.
- **Notes:**
  - Members are sorted by ascending `arenaIndex`.
  - A slot is only counted when it is `Occupied` with
    `occupantKind == 'Animal'` and the animal is **settled** — the animal
    must be `Slotted`, on that exact slot, not stolen, not carried, not
    mutexed, and `controller == nil` (a mid-walk animal sits the raid out).
  - Duplicate occupant ids are skipped with a warning.
  - **Combat stats are NOT resolved here** — only an identity snapshot. The
    stats are resolved canonically at battle creation.

### `ArenaService.ResolveArenaArea(base: any): { [string]: any }` — `ArenaService.lua:707`

Resolves the base's battle area.

- **Parameters:** `base` — the base record.
- **Returns:** `{ ready = boolean, center = CFrame?, missing = { string } }`.
- **Failure modes:**
  - `{ ready = false, center = nil, missing = { 'base folder' } }` for a base
    with no `folder`.
  - `missing` gets `'<full path>/Arena (folder)'` when the `Arena` folder is
    absent, `'Arena/Center'` when the center marker is missing, and
    `'Arena/PlayerSpawns'` / `'Arena/EnemySpawns'` when those folders are
    absent.
  - `ready` is `true` only when `center` resolved.
  - Never throws. A `warn` is emitted when anything is missing.

### `ArenaService.DebugArea(base: any)` — `ArenaService.lua:774`

Prints a one-shot hierarchy census of the base's `Arena` folder (names,
classes, full paths).

- **Parameters:** `base` — the base record.
- **Returns:** nothing.
- **Failure modes:** none — everything is inside a `pcall`. Intended to be
  called only on a validation failure.

### `ArenaService.GetSession(userId: number): { [string]: any }?` — `ArenaService.lua:836`

The player's live raid session.

- **Parameters:** `userId` — the player.
- **Returns:** the session table, or `nil`.
- **Failure modes:** returns `nil` for a non-number user id or when there is
  no session. Never throws.

### `ArenaService.IsAnimalRaidLocked(uniqueId: string): boolean` — `ArenaService.lua:849`

Whether an animal is locked into **any** active raid's immutable loadout.
Used by the sell / upgrade / grab / steal services.

- **Parameters:** `uniqueId` — the persistent animal id.
- **Returns:** `true` / `false`.
- **Failure modes:** returns `false` (fail-open) for a non-string, an empty
  string, or an unknown id, and when no raids are active. Never throws.

### `ArenaService.HasActiveRaid(userId: number): boolean` — `ArenaService.lua:868`

Whether the player has a live raid.

- **Parameters:** `userId` — the player.
- **Returns:** `true` when the session state is `'Active'` or
  `'Transitioning'`.
- **Failure modes:** returns `false` for a non-number user id or no
  session. Never throws.

### `ArenaService.ValidateStart(player: Player, _arenaLevel: any): { [string]: any }` — `ArenaService.lua:938`

The atomic start validation.

- **Parameters:**
  - `player` — the requesting player.
  - `_arenaLevel` — **ignored**. There is no level gate.
- **Returns:** `{ ok = boolean, error = string? }`.
- **Failure modes:** returns `{ ok = false, error = <code> }` — never
  throws. The order of checks is player → services → base → session →
  carry/steal → team.

### `ArenaService.StartArena(player: Player, option: any): { [string]: any }` — `ArenaService.lua:1251`

The ONE authoritative raid-start path.

- **Parameters:**
  - `player` — the requesting player.
  - `option` — `'Buy1'` | `'Buy2'` | `'Buy3'`. Anything else is coerced to
    `'Buy3'` (the free stage-1 entry) by `resolveRestartStart` (`:1220`).
- **Returns:**
  - Success: `{ success = true, sessionId = number, startLevel = number, option = string }`.
  - Failure: `{ success = false, error = string }`.
- **Failure modes** (each returns `{ success = false, error = ... }` and
  creates **no** session):
  - `'insufficient-funds'` — the economy charge failed (`:1326`).
  - `'already-active'` — lost the race; a second request created the
    session first. The debit is **refunded** (`:1334`).
  - `'battle-failed'` — `startStageBattle` failed. The debit is **refunded**
    (`:1404`).
  - `'service-not-ready'` — `battleServiceRef` is unset (`:1265`).
  - Any code from `validateStart` — e.g. `'invalid-player'`, `'no-team'`,
    `'restart-unavailable'`, `'session-exists'`.
  - Never throws.
- **Notes:**
  - The start stage and price are re-resolved server-side from the saved
    `LastReached`. Any client-sent level or price is ignored.
  - The team is trimmed to `MaxTeamSize` (3) by ascending `ArenaIndex`, with
    a loud warning. It is never silently reordered.
  - A debit that lands without a session is always refunded before
    returning.

### `ArenaService.StartRaid(player: Player): { [string]: any }` — `ArenaService.lua:1462`

A thin alias over `StartArena(player, 'Buy3')`.

- **Parameters:** `player`.
- **Returns / failure modes:** identical to `StartArena`.

### `ArenaService.cleanupBattleModels(session: { [string]: any }?, delaySec: number?)` — `ArenaService.lua:1480`

Idempotent battle-model teardown for one session.

- **Parameters:**
  - `session` — the session (its `battle` field is destroyed).
  - `delaySec` — optional deferral. `0` or absent destroys immediately.
- **Returns:** nothing.
- **Failure modes:**
  - Returns immediately for a non-table session or an unset
    `battleServiceRef`.
  - `delaySec` is clamped to `ArenaFeel.Combat.ModelCleanupMaxDelay` (5).
  - A NaN / negative delay is treated as `0` (immediate).
  - The deferred destroy is inside a `pcall`. Never throws.

### `ArenaService.CancelArena(player: Player): { [string]: any }` — `ArenaService.lua:1528`

Player-requested retreat. Ends the raid at its current stage.

- **Parameters:** `player` — the retreating player.
- **Returns:** `{ success = true }` on success, `{ success = false, error = ... }` otherwise.
- **Failure modes:**
  - `{ success = false, error = 'invalid-player' }` for a non-live player.
  - `{ success = false, error = 'no-session' }` when there is no session.
  - Never throws.
- **Notes:** settlement is progressive (the same path as a defeat) — cleared
  stages pay, the unplayed remainder forfeits. The completion toast is
  **suppressed** (a retreat is not a completion). The team is restored to
  its arena stands and the Adventurer is restored.

### `ArenaService.CancelBattleSilent(userId: number, sessionId: number, stageGen: number?)` — `ArenaService.lua:1594`

The silent cancel — a validator trip (leave, base loss, destroyed models).

- **Parameters:**
  - `userId` — the player.
  - `sessionId` — the session token.
  - `stageGen` — the stage generation. `nil` matches only `nil`.
- **Returns:** nothing.
- **Failure modes:**
  - Returns immediately for a non-number user id or session id.
  - Returns immediately if there is no session, the session id does not
    match, the session state is not `'Active'`, or the generation does not
    match.
  - Never throws.
- **Notes:** **no reward, no stage settlement, no toast.** The team still
  returns to its arena stands.

### `ArenaService.OpenArena(player: Player)` — `ArenaService.lua:1630`

Opens the raid menu — called by the Adventurer `ProximityPrompt`.

- **Parameters:** `player`.
- **Returns:** nothing.
- **Failure modes:** returns immediately for a non-live player. Never
  throws.
- **Notes:** pushes the full state snapshot with `Show = true`.

### `ArenaService.ForgetPlayer(userId: number)` — `ArenaService.lua:1652`

Called on leave.

- **Parameters:** `userId` — the leaving player.
- **Returns:** nothing.
- **Failure modes:** returns immediately for a non-number user id. A player
  with no session is a silent no-op. Never throws.
- **Notes:** terminates any active raid **with no further rewards**, restores
  the Adventurer, and drops the session.

### `ArenaService.CompleteBattle(userId: number, sessionId: number, won: boolean, stageGen: number?): { [string]: any }` — `ArenaService.lua:2820`

The battle-end callback. The only place a stage is settled or the raid
advances.

- **Parameters:**
  - `userId` — the player.
  - `sessionId` — the session token.
  - `won` — whether the player side won the stage.
  - `stageGen` — the stage generation. `nil` matches only `nil`.
- **Returns:**
  - Win, advanced: `{ success = true, won = true, advanced = true }`.
  - Win, final stage: `{ success = true, won = true, raidComplete = true }`.
  - Win, but no survivors: `{ success = true, won = true, advanced = false }`.
  - Loss: `{ success = true, won = false }`.
  - Rejected: `{ success = false, error = <code> }`.
- **Failure modes:**
  - `'invalid-args'` — a non-number id.
  - `'stale-session'` — no session, or the session id does not match.
  - `'stale-stage'` — the generation does not match.
  - `'already-settled'` — the session state is not `'Active'`, or the stage
    already settled.
  - Never throws. A rejected callback changes **nothing** — no accumulator
    write, no state write, no reward.

### `ArenaService.BuildState(player: Player): { [string]: any }?` — `ArenaService.lua:3053`

Builds the full arena state snapshot.

- **Parameters:** `player` — the player.
- **Returns:** the snapshot, or `nil` for a non-Player.
- **Failure modes:** returns `nil` when `player` is not a `Player` instance.
  Never throws.
- **Shape:**
  ```lua
  {
      Progression = { Level, XP, XPRequired, Wins, HighestCompleted },
      Levels = { { Level, Name, Description, Boss, Unlocked, State, RewardXP,
                   RewardCash, RewardCashText, Beaten }, ... },
      Session = { SessionId, ArenaLevel, Stage, MaxStage, StageName,
                  StageGeneration, State, TeamCount, AreaReady,
                  Battle?, Raid? } | nil,
      Loadout = { Members, Count, MinTeam, MaxTeam } | nil,
      LastRaid = { ... } | nil,
      Restart = { LastLevel, WarmupLevel, Buy1, Buy2, Buy3 },
      Dialogue = { Greeting, Normal, High, Boss },
  }
  ```
- **Notes:**
  - `Session.State` is one of `'Active'`, `'Transitioning'`,
    `'Completing'`, `'Cleaned'`.
  - `Levels[i].State` is `'completed'` | `'available'` | `'locked'`.
  - `Loadout` is `nil` while a session exists (it previews the pre-raid
    team).
  - The `Progression` fallback when `progressionServiceRef` is unset is
    `{ Level = 1, XP = 0, XPRequired = 100, Wins = 0 }`.

### `ArenaService.PushState(player: Player, show: boolean?)` — `ArenaService.lua:3228`

Builds the state and fires it to one client.

- **Parameters:**
  - `player` — the player.
  - `show` — `true` opens the menu (`state.Show = true`). `nil` / `false`
    leaves `Show = false`.
- **Returns:** nothing.
- **Failure modes:** returns immediately if `BuildState` returns `nil`. The
  remote fire is inside a `pcall`. Never throws.

### Test seams

These are exported for the specs only. They are **not** part of the
production API and their behaviour may change without notice.

| Function | Line | Notes |
|---|---|---|
| `ArenaService._TestReset()` | `:3407` | Clears `sessions`, `lastRaid`, `_advHidden`; resets `nextSessionId`. |
| `ArenaService._TestResolveRestart(userId: number, option: any)` | `:3417` | Resolves a `Buy1`/`Buy2`/`Buy3` purchase without a live player. Returns `{ option, startLevel, price }` or `{ error }`. |
| `ArenaService._TestInjectSession(userId: number, session: { [string]: any })` | `:3423` | Installs a synthetic session. |
| `ArenaService._TestSetRaidDeployment(session: { [string]: any }, deployed: boolean)` | `:3431` | Drives the stand-parking deploy/restore. |
| `ArenaService._TestTerminateRaid(...)` | `:3442` | Drives the terminal path. |
| `ArenaService._TestBuildResultAnimals(...)` | `:3462` | Drives the result-row builder. |
| `ArenaService._TestHideAdv(userId: number, base: any): boolean` | `:395` | Hides the base Adventurer. |
| `ArenaService._TestRestoreAdv(userId: number): boolean` | `:399` | Restores it. |
| `ArenaService._TestAdvHidden(userId: number): boolean` | `:403` | Whether it is currently hidden. |

---

## `ServerScriptService.Arena.ArenaBattleService`

### Dependency injection

| Function | Line | Notes |
|---|---|---|
| `ArenaBattleService.SetValidator(fn: ((any) -> boolean)?)` | `:116` | Per-tick battle validity check. `nil` clears it — with no validator, every battle is considered valid. |
| `ArenaBattleService.SetOnBattleEnd(fn: ((number, number, boolean, number?) -> ())?)` | `:120` | The battle-end callback. |
| `ArenaBattleService.SetOnBattleCancel(fn: ((number, number, number?) -> ())?)` | `:124` | The silent-cancel callback. |
| `ArenaBattleService.SetEventSink(fn: ((number, { [string]: any }) -> ())?)` | `:135` | The presentation/log feed. |
| `ArenaBattleService.SetAnimalService(svc: any)` | `:139` | `AnimalService` — models and `AddXP`. |

- **Returns:** nothing.
- **Failure modes:** none. The callbacks are invoked inside `pcall`s.

### `ArenaBattleService.BuildPlayerCombatant(member: any, positionIndex: number, now: number, cooldown: number, hpOverride: number?): (any?, string?)` — `ArenaBattleService.lua:199`

Builds one player combatant from a team member.

- **Parameters:**
  - `member` — `{ UniqueId, DefinitionId, DisplayName, Rarity, Level, Trait, Mutations, OwnerUserId }`.
  - `positionIndex` — the spawn slot (1-based).
  - `now` — the current time (used for `NextAttackAt`).
  - `cooldown` — the attack cooldown.
  - `hpOverride` — **raid carry-over HP**. When supplied, `CurrentHealth` is
    `clamp(hpOverride, 0, MaxHealth)` and `Alive` becomes
    `CurrentHealth > 0`. When omitted, the combatant starts at full HP.
- **Returns:** `(combatant, nil)` on success, `(nil, errorCode)` on failure.
- **Failure modes:**
  - `'bad-member'` — not a table.
  - `'bad-definition'` — no `DefinitionId` string.
  - `'bad-level'` — `Level` is not an integer `>= 1`.
  - `'stat-failed'` — `AnimalStats.Calculate` could not resolve Health or
    Damage.
  - `'bad-hp-override'` — `hpOverride` is a NaN number.
  - Never throws.

### `ArenaBattleService.BuildEnemyCombatant(enemyDef: any, positionIndex: number, now: number, cooldown: number): (any?, string?)` — `ArenaBattleService.lua:290`

Builds one enemy combatant from a catalog `EnemyTeam` entry.

- **Parameters:**
  - `enemyDef` — `{ DefinitionId, Level, StatMultiplier? }`.
  - `positionIndex` — the spawn slot (1-based).
  - `now` — the current time.
  - `cooldown` — the attack cooldown.
- **Returns:** `(combatant, nil)` on success, `(nil, errorCode)` on failure.
- **Failure modes:**
  - `'bad-enemy'` — not a table.
  - `'bad-definition'` — no `DefinitionId` string.
  - `'bad-level'` — `Level` is not an integer `>= 1`.
  - `'stat-failed'` — stats did not resolve.
  - Never throws.

### `ArenaBattleService.CreateBattle(userId: number, sessionId: number, arenaLevel: number, playerMembers: { any }, enemyDefs: { any }, cooldown: number, now: number, stageGeneration: number?, hpBySource: { [string]: number }?): (any?, string?)` — `ArenaBattleService.lua:350`

Creates a battle record. **Does not register it** — call `RegisterBattle`
separately.

- **Parameters:** as named. `hpBySource` maps a persistent animal
  `UniqueId` to its carried-over run HP.
- **Returns:** `(battle, nil)` on success, `(nil, errorCode)` on failure.
- **Failure modes:**
  - `'bad-ids'` — a non-number `userId` or `sessionId`.
  - `'empty-player-team'` — no player members.
  - `'empty-enemy-team'` — no enemy definitions.
  - `'player-combatant-failed:<code>'` — a player combatant failed to build.
  - `'enemy-combatant-failed:<code>'` — an enemy combatant failed to build.
  - `'all-dead'` — every player combatant is dead (nothing to fight with).
  - A non-positive / NaN `cooldown` is **coerced** to `FALLBACK_COOLDOWN`
    (1.5), not rejected.
  - Never throws.
- **Notes:** the animation PRNG seed is derived deterministically from
  `(userId, sessionId, arenaLevel)` (`:411-417`) — identical inputs replay
  identically. `nextTurnAt = now`, so the first strike is immediate.

### `ArenaBattleService.GetBattle(userId: number): { [string]: any }?` — `ArenaBattleService.lua:456`

The live battle for a player.

- **Returns:** the battle, or `nil`.
- **Failure modes:** returns `nil` for a non-number user id or no battle.
  Never throws.

### `ArenaBattleService.PickTarget(battle: { [string]: any }, attacker: { [string]: any }): { [string]: any }?` — `ArenaBattleService.lua:467`

Chooses the attacker's target.

- **Parameters:** the battle and the attacker.
- **Returns:** the target combatant, or `nil`.
- **Failure modes:** returns `nil` for a non-table battle or attacker, or
  when the opposing team has no living member. Never throws.
- **Notes:** prefers the living foe whose `PositionIndex` matches the
  attacker's; otherwise the **first** living foe in table order.

### `ArenaBattleService.TickBattle(battle: { [string]: any }, now: number): { [string]: any }` — `ArenaBattleService.lua:618`

Runs one turn of a battle.

- **Parameters:**
  - `battle` — the battle.
  - `now` — the current time.
- **Returns:** `{ events = { ... }, finished = 'won' | 'lost' | nil }`.
- **Failure modes:**
  - Returns `{ events = {}, finished = nil }` for a non-table battle, a
    non-`Active` battle, or a non-number `now`.
  - Returns early with no events when `now < battle.nextTurnAt`.
  - Sets `battle.state` / `battle.result` and returns
    `finished = 'won' | 'lost'` when a side has no living combatant.
  - Never throws.
- **Event shapes:**
  ```lua
  { type = 'attack', attackerId, attackerTeam, targetId, targetTeam,
    damage, targetHealth, targetMaxHealth, attackAnimation, soundIndex,
    attackSequence, impactPosition }
  { type = 'defeat', ... }
  ```

### `ArenaBattleService.RegisterBattle(battle: { [string]: any }): boolean` — `ArenaBattleService.lua:792`

Registers a battle with the scheduler.

- **Parameters:** `battle`.
- **Returns:** `true` on success, `false` on failure.
- **Failure modes:** returns `false` for a non-table battle, a missing
  numeric `userId`, or a battle whose state is not `'Active'`. Never
  throws.
- **Notes:** starts the shared `Heartbeat` scheduler if it was not running.

### `ArenaBattleService.UnregisterBattle(userId: number)` — `ArenaBattleService.lua:804`

Removes a battle from the scheduler.

- **Parameters:** `userId`.
- **Returns:** nothing.
- **Failure modes:** returns immediately for a non-number user id. Stops the
  scheduler when the registry becomes empty. Never throws.

### `ArenaBattleService.TickAll(now: number)` — `ArenaBattleService.lua:895`

The scheduler tick — advances every registered battle.

- **Parameters:** `now` — the current time.
- **Returns:** nothing.
- **Failure modes:** each battle is ticked inside its own `pcall` — one
  battle throwing **does not** stop the others (a `warn` is emitted).
  Never throws.

### `ArenaBattleService.ResolveBattlePositions(base: any, playerCount: number, enemyCount: number): { [string]: any }` — `ArenaBattleService.lua:1014`

Resolves the spawn positions for both teams.

- **Parameters:** the base record and the two team sizes.
- **Returns:** `{ ready = boolean, player = { CFrame }, enemy = { CFrame }, playerSurface = { Vector3? }, enemySurface = { Vector3? }, missing = { string } }`.
- **Failure modes:**
  - `ready = false` and `missing` gets `'base folder'` when the base has no
    `folder`.
  - `missing` gets `'<path>/Arena (folder)'`, `'Arena/PlayerSpawns (folder)'`,
    `'Arena/EnemySpawns (folder)'`, and per-slot entries like
    `'Arena/PlayerSpawns/Position3'`.
  - Never throws; markers are read inside `pcall`s.
- **Notes:** a marker may be a `BasePart` (its `CFrame`), an `Attachment`
  (its `WorldCFrame`), or a `Model` (its `GetPivot()`).

### `ArenaBattleService.SpawnBattleModels(battle: { [string]: any }, base: any): { [string]: any }` — `ArenaBattleService.lua:1219`

Spawns the combat models for both teams.

- **Parameters:** the battle and the base.
- **Returns:** `{ ok = true }` on success, `{ ok = false, error = <code> }` on failure.
- **Failure modes:**
  - `'bad-battle'` — not a table.
  - `'empty-team'` — either team is empty.
  - Any error code from the model-clone path (`'no-animal-service'`,
    `'unknown-definition'`, `'template-missing'`, `'clone-failed'`,
    `'model-missing'`).
  - Never throws.
- **Notes:** **all-or-nothing** — a single failure fails the whole spawn, so
  the caller rejects the battle start rather than running a lopsided fight.
  Player models prefer the **live** animal model (`cloneLiveAnimalModel`)
  and fall back to the template pipeline (`cloneTemplateModel`, which
  preserves the trait). Every `BasePart` is anchored with collision and
  touch disabled; `ProximityPrompt`s and the `OverheadGui` /
  `OverheadTemplate` billboards are stripped from the clone.

### `ArenaBattleService.DestroyBattleModels(battle: { [string]: any })` — `ArenaBattleService.lua:1427`

Tears down the battle's combat models.

- **Parameters:** `battle`.
- **Returns:** nothing.
- **Failure modes:** returns immediately for a non-table battle. The folder
  destroy and the ref clearing are inside a `pcall`. **Idempotent** — a
  second call is a no-op. Never throws.

### `ArenaBattleService.PresentAttack(battle: { [string]: any }, attack: { [string]: any }): number` — `ArenaBattleService.lua:1815`

Runs the server-side attack presentation: the travel tween, the in-place
flourish, the hit flash, the hit jolt, and the impact event.

- **Parameters:**
  - `battle` — the battle.
  - `attack` — the attack event from `TickBattle`
    (`{ attackerId, targetId, damage, attackAnimation, soundIndex, impactPosition, ... }`).
- **Returns:** the impact delay in seconds — `impactDelay + HIT_STOP`, where
  `impactDelay = (travelSkipped and 0 or TRAVEL_DUR) + spec.impactOffset`.
  Returns `0` when it cannot present.
- **Failure modes:** returns `0` for a non-table attack, a missing attacker
  or target, a missing live model, a missing home CFrame, or a missing foe
  pivot. The animation index is **clamped** to `1..5` (out-of-range → `1`).
  The sound index is clamped to `1..ArenaFeel.Sfx.SlotCount`. Never throws.
- **Notes:** the returned delay is computed from `spec.impactOffset`, but the
  actual visual contact lands after the **full** `spec.dur` flourish. Treat
  the return value as a scheduling hint, not the true contact time.

### `ArenaBattleService.CaptureKeepsake(battle: { [string]: any }, combatant: { [string]: any }?, model: Model?)` — `ArenaBattleService.lua:2063`

Clones a player combatant's model into the session's keepsake folder.

- **Parameters:**
  - `battle` — the battle.
  - `combatant` — the player combatant.
  - `model` — the model to clone. Defaults to the combatant's live model.
- **Returns:** nothing.
- **Failure modes:**
  - Returns immediately for a non-table battle or combatant.
  - Returns immediately for an **enemy** combatant (enemies are never kept)
    or one with no `SourceAnimalId`.
  - Returns immediately if the combatant was already captured (the
    idempotency guard) — death-time capture wins over stage-end capture.
  - Returns immediately when the model is missing or unparented.
  - Never throws — the whole capture is inside a `pcall`.

### `ArenaBattleService.CaptureLiveKeepsakes(battle: { [string]: any })` — `ArenaBattleService.lua:2120`

Captures the keepsakes for every player combatant that still has a live
model (the stage-end survivors).

- **Parameters:** `battle`.
- **Returns:** nothing.
- **Failure modes:** returns immediately for a non-table battle or a missing
  `playerTeam`. Never throws.

### `ArenaBattleService.TakeKeepsakes(battle: { [string]: any }): { [string]: Model }` — `ArenaBattleService.lua:2135`

Drains the battle's keepsakes for the raid session to accumulate.

- **Parameters:** `battle`.
- **Returns:** `{ [SourceAnimalId] = Model }`.
- **Failure modes:** returns an empty table for a non-table battle. Clones
  that are missing, unparented, or belong to a non-player combatant are
  skipped. The battle's keepsake table is **cleared**, so a repeated collect
  cannot duplicate them. Never throws.

### `ArenaBattleService.ClearSessionKeepsakes(sessionId: number)` — `ArenaBattleService.lua:2173`

Destroys one session's keepsake folder.

- **Parameters:** `sessionId` — the raid session id.
- **Returns:** nothing.
- **Failure modes:** a missing root or folder is a silent no-op. The whole
  call is inside a `pcall`. Never throws.

### `ArenaBattleService.PresentDeath(battle: { [string]: any }, combatantId: string, delaySec: number?)` — `ArenaBattleService.lua:2200`

Plays the death presentation: capture the keepsake, clear the model and
overhead references, fade the model out, then destroy it.

- **Parameters:**
  - `battle` — the battle.
  - `combatantId` — the combatant's `Id`.
  - `delaySec` — optional pre-fade delay, clamped to
    `ArenaFeel.DeathFade.MaxPreDelay` (2).
- **Returns:** nothing.
- **Failure modes:** returns immediately when the combatant is not found.
  Returns after clearing the refs when there is no live model. A NaN /
  negative delay is treated as `0`. Never throws.
- **Notes:** this only removes the combatant from **presentation** — the
  persistent result roster lives in `ArenaService.session.team` and is never
  touched here.

### `ArenaBattleService._TestReset()` — `ArenaBattleService.lua:2272`

Clears the battle registry and the keepsakes.

- **Parameters:** none.
- **Returns:** nothing.
- **Failure modes:** none.

---

## `ServerScriptService.Arena.ArenaProgressionService`

### `ArenaProgressionService.SetPlayerService(svc: any)` — `ArenaProgressionService.lua:42`

Injects the profile owner.

- **Returns:** nothing.
- **Failure modes:** none. Without it, every mutator is a no-op and every
  reader returns a default.

### `ArenaProgressionService.NormalizeArena(data: any): { [string]: any }?` — `ArenaProgressionService.lua:51`

Creates or repairs the profile's `Arena` sub-table.

- **Parameters:** `data` — the profile data table.
- **Returns:** the normalized `Arena` table, or `nil`.
- **Failure modes:** returns `nil` for a non-table profile (with a `warn`).
  Never throws.
- **Normalizes:** `Level` (integer `1..MaxLevel`), `XP` (number `>= 0`),
  `Wins` (integer `>= 0`), `HighestCompleted` (integer `0..MaxLevel`),
  `LastReached` (integer `0..MaxLevel`), `PendingEggs` (table).
- **Note:** it does **not** create a `LastLevel` field — that field does
  not exist.

### `ArenaProgressionService.AddXPToData(arena: { [string]: any }, amount: number): { [string]: any }` — `ArenaProgressionService.lua:104`

The pure level-up core.

- **Parameters:**
  - `arena` — a normalized arena table (mutated in place).
  - `amount` — the arena XP to add.
- **Returns:** `{ LevelsGained = number, Level = number }`.
- **Failure modes:**
  - For a non-number, NaN, or `<= 0` amount, returns
    `{ LevelsGained = 0, Level = arena.Level }` — **the XP is NOT added**.
  - Never throws.
- **Notes:** levels up while the threshold is met. Capped at `MaxLevel`;
  overflow XP is **banked, never lost**. `XPRequired` returns `nil` at the
  cap, which terminates the loop.

### `ArenaProgressionService.GetArenaLevel(playerOrUserId: any): number` — `ArenaProgressionService.lua:151`

The player's arena XP level.

- **Parameters:** a `Player` or a user id.
- **Returns:** the level. **Always a valid number** — `1` for an unknown
  player.
- **Failure modes:** returns `1` for an unknown player or a missing
  profile. Never throws.

### `ArenaProgressionService.GetArenaXP(playerOrUserId: any): number` — `ArenaProgressionService.lua:163`

The player's arena XP.

- **Parameters:** a `Player` or a user id.
- **Returns:** the XP. `0` for an unknown player.
- **Failure modes:** returns `0` for an unknown player or a missing
  profile. Never throws.

### `ArenaProgressionService.GetArenaState(playerOrUserId: any): { [string]: any }` — `ArenaProgressionService.lua:176`

The full progression snapshot for the menu.

- **Parameters:** a `Player` or a user id.
- **Returns:** `{ Level, XP, XPRequired, Wins, HighestCompleted }`.
- **Failure modes:** never throws. `XPRequired` is `nil` at the cap.
  Unknown players read `Level = 1, XP = 0, Wins = 0,
  HighestCompleted = 0`.

### `ArenaProgressionService.GetHighestCompleted(playerOrUserId: any): number` — `ArenaProgressionService.lua:205`

The highest stage the player has **cleared**.

- **Parameters:** a `Player` or a user id.
- **Returns:** the stage, or `0` for none.
- **Failure modes:** **fail-closed** — an unknown profile reads `0`. Never
  throws.

### `ArenaProgressionService.IsUnlocked(playerOrUserId: any, arenaLevel: number): boolean` — `ArenaProgressionService.lua:226`

Whether a stage is reachable given the player's cleared history
(`arenaLevel <= HighestCompleted + 1`).

- **Parameters:** a `Player` or a user id, and the stage.
- **Returns:** `true` / `false`.
- **Failure modes:** returns `false` for an invalid stage. Never throws.
- **Note:** **no production caller.** The raid model has no start gate.

### `ArenaProgressionService.AddArenaXP(userId: number, amount: number): { [string]: any }` — `ArenaProgressionService.lua:235`

The server-side arena XP grant.

- **Parameters:** `userId` and the XP amount.
- **Returns:** `{ LevelsGained = number, Level = number }`.
- **Failure modes:** returns `{ LevelsGained = 0, Level = 1 }` for a
  non-number user id, an unset `playerServiceRef`, or a missing profile.
  Never throws (the whole body is inside a `pcall`).

### `ArenaProgressionService.RecordWin(userId: number): number` — `ArenaProgressionService.lua:255`

Increments `Wins` by one.

- **Parameters:** `userId`.
- **Returns:** the new `Wins` count, or `0` on failure.
- **Failure modes:** returns `0` for an unset `playerServiceRef` or a
  missing profile. Never throws.
- **Note:** **no production caller** — only `Tests/Arena.spec.lua:169`. The
  live path is `RecordLevelWin`.

### `ArenaProgressionService.RecordLevelWin(userId: number, arenaLevel: number): { [string]: any }` — `ArenaProgressionService.lua:277`

Records one cleared stage.

- **Parameters:** `userId` and the cleared stage.
- **Returns:** `{ Wins = number, HighestCompleted = number, FirstClear = boolean }`.
- **Failure modes:** returns `{ Wins = 0, HighestCompleted = 0,
  FirstClear = false }` for an unset `playerServiceRef`, a non-number stage,
  or a missing profile. Never throws.
- **Notes:** `Wins` always increments. `HighestCompleted` advances
  **strictly sequentially** — only when `arenaLevel ==
  HighestCompleted + 1` — so replays never move it and forged gap stages can
  never create a gap. `FirstClear` is `true` exactly on that advancing
  write.

### `ArenaProgressionService.GetLastReached(playerOrUserId: any): number` — `ArenaProgressionService.lua:310`

The highest stage the player has **reached** (in a terminal raid, win or
lose). Drives the paid-restart entry.

- **Parameters:** a `Player` or a user id.
- **Returns:** the stage, or `0` for none.
- **Failure modes:** returns `0` for an unknown player or a missing
  profile. Never throws.

### `ArenaProgressionService.RecordReachedLevel(userId: number, stage: number): number` — `ArenaProgressionService.lua:326`

Records a terminal raid's reached stage.

- **Parameters:** `userId` and the stage reached.
- **Returns:** the new `LastReached`, or `0` on failure.
- **Failure modes:** returns `0` for an unset `playerServiceRef`, a
  non-number stage, or a missing profile. Never throws.
- **Notes:** **max-only** — the value never moves backwards, so a later
  shorter run cannot erase progress. A stage `< 1` or `> MaxLevel` is
  ignored. Called once per terminal raid (victory, defeat, mutual wipe) —
  **never on a retreat**.

### `ArenaProgressionService.ResetArena(userId: number): boolean` — `ArenaProgressionService.lua:352`

Resets the arena progression (for a Rebirth).

- **Parameters:** `userId`.
- **Returns:** `true` on success, `false` on failure.
- **Failure modes:** returns `false` for a non-number user id, an unset
  `playerServiceRef`, or a missing profile. Never throws.
- **Notes:** clears `Level` / `XP` / `Wins` / `HighestCompleted` /
  `LastReached` / `PendingEggs` back to their fresh-profile values.

### `ArenaProgressionService._TestReset()` — `ArenaProgressionService.lua:345`

Clears the injected `PlayerService`.

- **Parameters:** none.
- **Returns:** nothing.
- **Failure modes:** none.

---

## Related

- [README.md](README.md) — overview, entry points, limitations.
- [MEMORY.md](MEMORY.md) — step-by-step mechanics and gotchas.
- [Dependencies.md](Dependencies.md) — require paths, remotes, assets, init order.
- [Setup.md](Setup.md) — install into a new Rojo project.
- [Config.lua](Config.lua) — the consolidated tunable mirror.
