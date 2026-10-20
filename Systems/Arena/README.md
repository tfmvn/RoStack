# Arena

Server-authoritative arena expeditions: a player locks a team of animals into
arena stands, starts a raid, and fights a continuous run of stage battles
until the run ends.

**Portability:** Grade A core (the session shell, the deterministic combat
engine, the settlement math, the staleness model) + Grade B adapter (the
50-stage catalog, the enemy roster, the Adventurer prompt wiring, the
result-card presentation, and the four injected service seams that are
tied to Brainrot Arena's base/slot/carry/steal architecture).

**Source game:** Brainrot Arena (`p-7`).

---

## What It Does

The Arena system runs **continuous multi-stage raids**, not one-shot
"challenge a stage" battles.

- **A raid session is per-player and continuous.** The player presses the
  Adventurer prompt, the server resolves their occupied arena slots into an
  immutable team snapshot, and the raid advances stage by stage until the
  team dies, the player retreats, or the catalog is exhausted.
- **The team carries HP across stages.** Raid HP lives on the session
  (`session.raidHP` / `session.raidAlive`), keyed by animal `UniqueId`. It
  is **never** written back to the persistent animal record. Dead animals
  stay dead for the rest of the run; there is no healing and no revival.
- **Settlement is progressive.** Each cleared stage is settled as it is
  cleared. A defeat or a retreat pays the cleared stages and forfeits the
  remainder. Winning the whole run pays the full accumulator.
- **The combat engine is deterministic.** One centralized
  `RunService.Heartbeat` scheduler drives every active battle on the
  server at `ArenaFeel.Combat.TickInterval` (0.25s). One attack per turn,
  Player side first, alternating, with `PositionIndex` round-robin target
  selection. The only randomness is a seeded LCG used to pick the attack
  animation index.
- **Every stage is protected against stale callbacks.** Each battle carries
  a `(sessionId, stageGeneration)` token. A callback from a previous stage
  of the same session is rejected outright — it can neither settle a stage
  nor pay a reward.
- **Results show the real models.** The server captures pristine clones of
  the actual combat models into `ReplicatedStorage.ArenaResultModels/Session_<id>`
  ("keepsakes"). The result card renders those clones, never a template and
  never a placeholder.

The system is **server + config only**. It has no client code — see
[Known Limitations](#known-limitations).

---

## Entry Points

| Entry point | Kind | Notes |
|---|---|---|
| `ArenaService.Init()` | Server | Wires the `ArenaAction` remote, installs the battle validator / end / cancel / event callbacks, and late-join self-heals the Adventurer prompt on every occupied base. Idempotent. |
| `ArenaService.OpenArena(player)` | Server | Called by the Adventurer `ProximityPrompt`. Pushes the full arena state snapshot with `Show = true` so the client opens the menu. |
| `ArenaService.StartArena(player, option)` | Server | The ONE authoritative raid-start path. `option` is `'Buy3'` (free, stage 1), `'Buy1'` (paid warmup restart), or `'Buy2'` (paid direct restart). The server re-resolves the start stage and price from the saved `LastReached`; any client-sent level or price is ignored. |
| `ArenaService.StartRaid(player)` | Server | Thin wrapper over `StartArena(player, 'Buy3')`. |
| `ArenaService.CancelArena(player)` | Server | Player-requested retreat. Settles cleared stages progressively, restores the team to their stands, restores the Adventurer. |
| `ArenaService.CancelBattleSilent(userId, sessionId, stageGen?)` | Server | Validator-trip cancel (leave, base loss, destroyed models). No reward, no stage settlement. |
| `ArenaService.CompleteBattle(userId, sessionId, won, stageGen?)` | Server | The battle-end callback. Advances the stage, settles the stage reward, or ends the raid. |
| `ArenaService.BuildState(player)` | Server | Builds the full arena state snapshot (`Progression`, `Levels`, `Session`, `Loadout`, `LastRaid`, `Restart`, `Dialogue`). Returns `nil` for a non-Player. |
| `ArenaService.PushState(player, show?)` | Server | `BuildState` + fire `ArenaState` to that one client. `show = true` opens the menu. |
| `ArenaService.ForgetPlayer(userId)` | Server | Called on leave. Terminates any active raid with no further rewards and drops the session. |
| `ArenaService.EnsureAdventurer(base)` | Server | Resolves the base's Adventurer host (authored `Adventurer` → authored `Adv` → temporary code-built NPC) and installs the prompt. Idempotent. |
| `ArenaService.GetSession(userId)` | Server | The live session table, or `nil`. |
| `ArenaService.HasActiveRaid(userId)` | Server | `true` when the session state is `'Active'` or `'Transitioning'`. |
| `ArenaService.IsAnimalRaidLocked(uniqueId)` | Server | `true` when an animal is in any active raid's immutable loadout. Fail-open (returns `false`) for unknown ids. |
| `ArenaService.ResolveArenaTeam(userId)` | Server | Resolves the arena-slot team for a base. Used by the raid path and the menu's loadout preview. |
| `ArenaService.ResolveArenaArea(base)` | Server | Resolves the base's battle area and spawn markers; reports what is missing. |
| `ArenaService.ValidateStart(player, _arenaLevel)` | Server | Atomic start validation. `_arenaLevel` is **ignored** — there is no level gate. |
| `ArenaService.Set*Service(svc)` (10 setters) | Server | Late-bound dependency injection. See [Dependencies.md](Dependencies.md). |
| `ArenaProgressionService.NormalizeArena(data)` | Server | Repairs/creates the `Arena` sub-table on a profile. Returns the normalized table, or `nil` for a non-table. |
| `ArenaProgressionService.AddArenaXP(userId, amount)` | Server | Adds arena XP to a player's profile and levels them up. |
| `ArenaProgressionService.RecordLevelWin(userId, arenaLevel)` | Server | Records one cleared stage: increments `Wins`, updates `HighestCompleted`, returns `FirstClear` on the first clear of that stage. |
| `ArenaProgressionService.RecordReachedLevel(userId, stage)` | Server | Records the highest stage ever *reached* (not cleared). Monotonic. |
| `ArenaProgressionService.GetArenaState(playerOrUserId)` | Server | The progression snapshot for a player or user id. |
| `ArenaProgressionService.ResetArena(userId)` | Server | Resets the arena progression to defaults. |
| `ArenaBattleService.CreateBattle(userId, sessionId, arenaLevel, playerMembers, enemyDefs, cooldown, now, stageGeneration?, hpBySource?)` | Server | Creates a battle and registers it with the scheduler. Returns `(battle?, error?)`. |
| `ArenaBattleService.TickAll(now)` | Server | The scheduler tick. Called by the single `Heartbeat` connection. |
| `ArenaBattleService.SetValidator(fn)` / `SetOnBattleEnd(fn)` / `SetOnBattleCancel(fn)` / `SetEventSink(fn)` | Server | Late-bound callbacks installed by `ArenaService.Init()`. |

Full signatures and failure modes: [API.md](API.md).

---

## Files

| Library path | Roblox destination | Purpose |
|---|---|---|
| `Source/ServerScriptService/Arena/ArenaService.lua` | `ServerScriptService.Arena.ArenaService` | The raid shell: sessions, start/settle/advance, team resolution, state building, the `ArenaAction` remote ingress, Adventurer prompt wiring. |
| `Source/ServerScriptService/Arena/ArenaBattleService.lua` | `ServerScriptService.Arena.ArenaBattleService` | The combat engine: combatants, the scheduler, turn choreography, damage, models, keepsakes, presentation hooks. |
| `Source/ServerScriptService/Arena/ArenaProgressionService.lua` | `ServerScriptService.Arena.ArenaProgressionService` | Owns the profile's `Arena` sub-table: XP, level, wins, highest completed, last reached, reset. |
| `Source/ReplicatedStorage/Config/World/Arena.lua` | `ReplicatedStorage.Config.World.Arena` | The 50-stage catalog and the gameplay tunables. `Validate()` / `ValidateList()` / `ValidateLive()`. |
| `Source/ReplicatedStorage/Config/World/ArenaFeel.lua` | `ReplicatedStorage.Config.World.ArenaFeel` | Presentation tunables (motion, flashes, damage numbers, camera shake, VFX/SFX, menu palette). |
| `Tests/Arena.spec.lua` | — | Config, progression, service, and Adventurer coverage. |
| `Tests/ArenaRaid.spec.lua` | — | Raid HP carry-over, completion, staleness, multiplayer isolation, settlement guards, terminal races. |
| `Tests/ArenaBattle.spec.lua` | — | Combatants, targeting, battles, turn choreography, keepsakes, positions, model lifecycle. |
| `Tests/ArenaDeployment.spec.lua` | — | Overhead generation visibility, stand parking, stand menu, collector escrow, raid deployment wiring. |
| `Tests/ArenaResult.spec.lua` | — | Server snapshot, the reward pipeline, client presentation. |
| `Tests/ArenaSlots.spec.lua` | — | Slot index namespace, slot registry, prompts, stand compatibility. |
| `Tests/ArenaUIState.spec.lua` | — | The result-open flag and the client screen state (requires modules from the ClientPresentation system). |

---

## Configuration

The system **has its own config** — two modules. See [Config.lua](Config.lua)
for a single consolidated, comment-annotated mirror of every tunable.

| Module | What it holds |
|---|---|
| `ReplicatedStorage.Config.World.Arena` | The 50-entry `LEVELS` catalog (enemy rosters, names, boss flags, per-stage rewards) and the gameplay tunables: `MaxLevel`, `MinTeamSize`, `MaxTeamSize`, `AnimalXPMultiplier`, `AttackCooldown`, `RestartWarmupPrice`, `RestartDirectPrice`, `ResultCardCap`. Plus the arena XP curve (`XPRequired`), the restart-stage resolvers, and `DIALOGUE`. |
| `ReplicatedStorage.Config.World.ArenaFeel` | Presentation only: `Combat` (motion, hit stop, tick/turn intervals, cleanup clamp), `AttackAnims` (5 entries), `HitFlash`, `AttackerCue`, `HitJolt`, `DeathFade`, `DamageNumber`, `CameraShake`, `Vfx`, `Sfx`, `Anchor`, `Menu`, `AdventurerPlaceholder`. |

Two more tunables live in **other** systems' config:

| Value | Lives in | Default | Meaning |
|---|---|---|---|
| `Prompts.Arena` | `Config/World/Prompts.lua` (Carry system) | `'Open Arena'` / `'Adventurer'` / hold `0` / `12` studs / no LOS | The Adventurer `ProximityPrompt`. |
| `Debug.ServerDebug` | `Config/Systems/Debug.lua` (SharedUtilities system) | `false` | Gates every `Debug.Log` / `Debug.Warn` line in the Arena. **All Arena telemetry is dormant in production.** |

### Catalog entry shape (`ArenaLevelDef`)

```lua
{
    Level = 1,                        -- number, 1..50, contiguous
    Name = 'Meadow Skirmish',          -- string
    Description = '...',               -- string
    Boss = false,                      -- boolean
    EnemyTeam = {                      -- 1..3 enemy definitions
        { DefinitionId = 'Frog', Level = 1 },
    },
    Rewards = {
        ArenaXP = 2,                   -- number, player arena XP for clearing this stage
        FirstClearCash = '15000',      -- BigNumber decimal STRING
        RepeatCash = '500',            -- BigNumber decimal STRING
    },
}
```

`DefinitionId` must resolve through `ReplicatedStorage.Config.Creatures.Animals`
(the **Animals** system). `ArenaConfig.ValidateLive()` checks exactly that.

---

## Dependencies

Full detail: [Dependencies.md](Dependencies.md). The load-bearing ones:

- `ReplicatedStorage.Config.World.Arena` / `.World.ArenaFeel` / `.World.Prompts` — the system's own config plus the prompt config (Carry system).
- `ReplicatedStorage.Utility.Remotes` — `ArenaAction`, `ArenaState`, `ArenaResult`, `ArenaCombatEvent`.
- `ReplicatedStorage.Utility.Validation` — `Validation.LivePlayer` guards every player-facing entry point.
- `ReplicatedStorage.Utility.BigNumber` — all cash is a BigNumber decimal string.
- `ReplicatedStorage.Utility.Debug` — the gated telemetry.
- `ReplicatedStorage.Utility.AnimalStats` — HP / attack stat resolution.
- `ReplicatedStorage.Types.SlotType` — the slot namespace, including `ArenaSlotIndexBase = 1000`.
- `ReplicatedStorage.Types.TransactionReason` — `ArenaReward`, `ArenaRestart`, `ArenaRestartRefund`.
- `ServerScriptService.Tutorial.TutorialSignals` — fires `ArenaStarted` / `ArenaCancelled` / raid-end milestones.
- `ServerScriptService.FunnelService` — funnel analytics (`LogStep`, `IsArenaMilestone`).
- `ServerScriptService.PlayerLogger.PlayerLogger` — milestone logging.
- `ServerScriptService.Animal.AnimalOverhead` / `.Animal.SlotMath` — overhead refresh and standing CFrame math.
- `ReplicatedStorage.Config.Creatures.Animals` — the enemy/player definition catalog (Animals system).

**Other systems required** (injected at boot, not `require`d by the Arena
modules): PlayerData, BasesAndSlots, Animals, Inventory, Carry, Stealing,
Economy, Analytics, Tutorials, PlayerLogging, SharedUtilities.

---

## Initialization Order

From the source game's `bootstrap.server.lua:521-536`:

```text
1.  Remotes folder must exist (Remotes.GetFolder()).
2.  ArenaProgressionService.SetPlayerService(PlayerService)
3.  ArenaService.SetPlayerService(PlayerService)
4.  ArenaService.SetBaseService(BaseService)
5.  ArenaService.SetAnimalService(AnimalService)
6.  ArenaService.SetSlotService(SlotService)
7.  ArenaService.SetCarryRegistry(CarryRegistry)
8.  ArenaService.SetStealService(StealService)
9.  ArenaService.SetNotificationService(NotificationService)
10. ArenaService.SetProgressionService(ArenaProgressionService)
11. ArenaService.SetEconomyService(EconomyService)
12. ArenaService.SetBattleService(ArenaBattleService)
13. ArenaBattleService.SetAnimalService(AnimalService)
14. ArenaService.Init()
```

`Init()` must run **after** every setter it depends on: it reads
`battleServiceRef` to install the validator / end / cancel / event
callbacks, and it asserts on the `ArenaAction` remote.

Per-player hooks (in the source game's bootstrap):

```text
On base assignment:  ArenaService.EnsureAdventurer(base)   -- pcall'ed
On player ready:     ArenaProgressionService.NormalizeArena(profile)
On player leave:     ArenaService.ForgetPlayer(userId)
```

`NormalizeArena` runs on load so older saves gain
`{ Level = 1, XP = 0, Wins = 0 }` without touching any other field.

---

## Data

### Profile fields

The Arena owns exactly one profile sub-table, `Data.Arena`:

| Field | Type | Default | Owner | Meaning |
|---|---|---|---|---|
| `Level` | number | `1` | ArenaProgressionService | The player's **arena XP** level. Separate from animal levels. |
| `XP` | number | `0` | ArenaProgressionService | Arena XP toward the next arena level. |
| `Wins` | number | `0` | ArenaProgressionService | Lifetime cleared stages. |
| `HighestCompleted` | number | `0` | ArenaProgressionService | Highest stage ever **cleared**. Drives first-clear vs repeat cash. |
| `LastReached` | number | `0` | ArenaProgressionService | Highest stage ever **reached**. Drives the paid-restart start stage. Monotonic. |
| `PendingEggs` | array | `{}` | ArenaProgressionService | Egg rewards pending delivery from arena runs. |

> **There is no `Arena.LastLevel` profile field.** "LastLevel" is the
> *concept* the restart resolvers take as input — the persisted field is
> `LastReached`, read live via `GetLastReached`. `LastLevel` appears only
> as a **key in the `Restart` block of the `ArenaState` payload**
> (`buildRestartInfo`, `ArenaService.lua:3033`), and it is
> `max(1, LastReached)` — a display floor, not a stored value.

### In-memory session state (never persisted)

| Field | Meaning |
|---|---|
| `sessionId` | Monotonic token, `nextSessionId`. Unique per raid. |
| `userId` | The owning player. |
| `kind` | Always `'Raid'`. |
| `arenaLevel` | The current stage. Always starts at 1 for a fresh raid. |
| `maxLevel` | The catalog ceiling for this run. |
| `stageGeneration` | Incremented on every stage advance. The staleness token. |
| `state` | `'Active'` \| `'Transitioning'` \| `'Cleaned'`. |
| `team` | The **immutable** loadout snapshot taken at start. |
| `raidHP` / `raidAlive` | Run HP by animal `UniqueId`. Never written back to persistent animals. |
| `rewardedStages` / `settledStages` | Per-stage idempotency sets. |
| `areaReady` | Whether the base's battle area resolved. |
| `startedAt` | Unix seconds. |
| `battle` | The current stage battle only. |

### Keepsake models

`ReplicatedStorage.ArenaResultModels/Session_<sessionId>/` holds pristine
clones of the actual combat models. `KEEPSAKE_ROOT_NAME = 'ArenaResultModels'`
(`ArenaBattleService.lua:2041`), `KEEPSAKE_TTL_S = 180` (`:2042`) — the
keepsakes expire after 180 seconds.

---

## Known Limitations

- **The system has no client code.** The Arena menu, the hit presentation,
  the camera impacts, and the result card live in the **ClientPresentation**
  system (`StarterPlayerScripts.ArenaController`, `ArenaHitPresentation`,
  `ArenaCameraImpacts`, `ArenaResultController`), and the screen-lifecycle
  coordinator lives in `ReplicatedStorage.Utility.ArenaUIState` (the Shared
  folder). Copying only `Systems/Arena/` gives you a server that fights
  correctly and shows nothing. You must copy the client modules too.
- **`ArenaFeel.Combat.EasingStyle` is never read.** `tweenModelTo` hardcodes
  `Enum.EasingStyle.Quad` (`ArenaBattleService.lua:1514`). Setting it to
  `'Sine'` changes nothing.
- **`ArenaConfig.IsUnlocked` and `ArenaProgressionService.IsUnlocked` have
  no production caller.** `ArenaConfig.IsUnlocked` is only exercised by
  `Tests/Arena.spec.lua:52-56`; `ArenaProgressionService.IsUnlocked` is
  exported but never called. There is **no level gate** on starting a raid —
  the source says so explicitly (`ArenaService.lua:876-881`).
- **`ArenaProgressionService.RecordWin` has no production caller** — only
  `Tests/Arena.spec.lua:169`. The live path is `RecordLevelWin`.
- **`ArenaService.ResolveTeam` is test-only.** The live team resolver is
  `ResolveArenaTeam` (arena slots, not base slots).
- **`ArenaConfig.AttackCooldown` does not set the attack cadence.** The
  value is stamped into `NextAttackAt` as a diagnostic, but the real turn
  pacing is `ArenaFeel.Combat.TurnInterval` (1.1s). Changing the cooldown
  alone does not change how fast fights feel.
- **`Config.lua` in this folder is a mirror, not the source of truth.** The
  services `require` `Config/World/Arena` and `Config/World/ArenaFeel`
  directly. Editing `Config.lua` alone does nothing (see the file header).
- **`ArenaConfig.MAX_LEVEL` is reassigned at `Arena.lua:1057`.** The constant
  starts as `10` at line 72 and is re-derived as `#LEVELS` (50) once the
  catalog is built. The literal `10` is dead.
- **`ArenaFeel.DeathFade.Steps` has a stale comment.** The source comment
  says "CURRENT: 5"; the actual value is `3`.
- **The `PendingEggs` arena field is not consumed by this system.** It is
  declared by the progression service but the reward pipeline in this
  system only produces the `Eggs` array on the result payload.
- **`PresentAttack` returns an impact delay computed from
  `spec.impactOffset`, but the actual visual contact lands after the full
  `spec.dur` flourish.** The returned number is a scheduling hint, not the
  true contact time.
- **All Arena telemetry is silent in production.** `Debug.Log` / `Debug.Warn`
  are gated on `Config.Systems.Debug.ServerDebug = false`. Every warning in
  this system — including real config errors — is invisible by default.
- **`ValidateLive()` warns, it does not fail.** `ArenaService.Init()` prints
  config issues as `warn()` and continues to wire up.

---

## Testing

The specs live in `Tests/`:

| Spec | Covers |
|---|---|
| `Arena.spec.lua` | `ArenaConfig` (7 cases), `ArenaProgressionService` (7), `ArenaService` (3), `ArenaService.EnsureAdventurer` (5). |
| `ArenaRaid.spec.lua` | Raid HP carry-over, raid completion, stale-callback protection, multiplayer isolation, engine transition, settlement guards, terminal races, restart progress, Adventurer visibility, raid locks. |
| `ArenaBattle.spec.lua` | Combatants, targeting, full battles, combat guarantees, turn choreography, battle settlement, keepsakes, the combat catalog, positions, `ResolveArenaArea`, visual lifecycle, silent cancel, multiplayer settlement. |
| `ArenaDeployment.spec.lua` | Overhead generation visibility, stand parking, stand menu, collector escrow, raid deployment wiring. |
| `ArenaResult.spec.lua` | Server snapshot, the reward pipeline, client presentation. |
| `ArenaSlots.spec.lua` | Slot index namespace, `SlotService` registry, prompts, stand compatibility, `ResolveArenaTeam`. |
| `ArenaUIState.spec.lua` | The result-open flag semantics and the client screen state. **Requires `ReplicatedStorage.Utility.ArenaUIState` and `StarterPlayer.StarterPlayerScripts.ArenaController` — both outside this system.** |

Run them with TestEZ through `ReusableSystems/Tests/TestRunner.server.lua`.
They still require Roblox Studio (they stub the profile and the remotes via
`_Helpers`; no DataStore is touched). See `../../Tests/README.md`.

---

## Adapting to a New Game

1. **Copy the three services** to `ServerScriptService/Arena/` and the two
   config modules to `ReplicatedStorage/Config/World/`. The `require` paths
   resolve unchanged if you keep those locations.
2. **Rewrite the catalog.** `Arena/Source/ReplicatedStorage/Config/World/Arena.lua`
   holds a 50-entry `LEVELS` array with Brainrot Arena's exact enemy rosters
   and reward numbers. Replace it with your own. Keep the `ArenaLevelDef`
   shape and keep `Level` contiguous from 1 — `MaxLevel` is derived as
   `#LEVELS`, and `XPRequired` is defined for `1 .. #LEVELS-1`.
3. **Make every `DefinitionId` resolve.** `ValidateLive()` probes
   `ReplicatedStorage.Config.Creatures.Animals`. An unknown id is a
   config warning at boot and a broken enemy at runtime.
4. **Author the battle area.** Under each base folder: an `Arena` folder
   containing `PlayerSpawns/Position1..3` and `EnemySpawns/Position1..3`.
   `ResolveArenaArea` reports what is missing.
5. **Author the Adventurer.** Put a `Model` or `BasePart` named
   `Adventurer` (or `Adv`) inside the base folder. Without one, the server
   builds a clearly marked temporary brick NPC — fine for a prototype, not
   for a shipped game.
6. **Copy the client modules** from the ClientPresentation system, or write
   your own. The server pushes `ArenaState` / `ArenaResult` /
   `ArenaCombatEvent` and expects the client to render them.
7. **Wire the injections.** You need ten services to exist and be injected
   before `ArenaService.Init()` — see [Initialization Order](#initialization-order).
   The settlement path needs `EconomyService.TrySpendMoney` and
   `PlayerService.GetPlayerData`.
8. **Keep the arena XP curve.** `XPRequired` is `floor(5 * 1.25^(L-1) + 0.5)`
   and the settle ratios were calibrated against it. The source warns that
   flat 100-per-level "collapsed against exponential settles (one full
   clear capped the whole track)" — do not linearize it without re-solving
   the ratios.
9. **Decide the restart economics.** `RestartWarmupPrice` (`'25000'`) and
   `RestartDirectPrice` (`'150000'`) are BigNumber strings charged through
   `EconomyService.TrySpendMoney` with `TransactionReason.ArenaRestart`.
10. **Keep `MaxTeamSize = 3` unless you re-author the spawn markers.** The
    cap is not a tuning knob: the arena authors exactly three player spawn
    positions, and the battle fails to spawn with `positions-not-ready`
    otherwise.

---

## Related

- [MEMORY.md](MEMORY.md) — dense engineering notes for a future agent.
- [API.md](API.md) — every public function, grouped by module.
- [Dependencies.md](Dependencies.md) — exact require paths, remotes, profile fields, assets, init order.
- [Setup.md](Setup.md) — install into a new Rojo project.
- [Config.lua](Config.lua) — the consolidated tunable mirror.
