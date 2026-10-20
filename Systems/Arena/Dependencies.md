# Arena — Dependencies

Exact, copy-pasteable. Every path is the **original Roblox path** — the
library's `Source/` tree mirrors it, so `require` calls resolve unchanged when
you copy the tree to the same place.

---

## Module Requires

### `ServerScriptService/Arena/ArenaService.lua`

```lua
require(ReplicatedStorage.Config.World.Arena)
require(ReplicatedStorage.Config.World.ArenaFeel)
require(ReplicatedStorage.Config.World.Prompts)
require(ReplicatedStorage.Types.SlotType)
require(ReplicatedStorage.Utility.Remotes)
require(ReplicatedStorage.Utility.Validation)
require(ReplicatedStorage.Utility.BigNumber)
require(ReplicatedStorage.Types.TransactionReason)
require(ReplicatedStorage.Utility.Debug)
require(ReplicatedStorage.Utility.AnimalStats)
require(script.Parent.Parent.Tutorial.TutorialSignals)
require(script.Parent.Parent.FunnelService)
require(script.Parent.Parent.PlayerLogger.PlayerLogger)
```

(`ArenaService.lua:84-99`.)

### `ServerScriptService/Arena/ArenaBattleService.lua`

```lua
require(ReplicatedStorage.Utility.Debug)
require(ReplicatedStorage.Utility.AnimalStats)
require(ReplicatedStorage.Config.Creatures.Animals)
require(ReplicatedStorage.Config.World.ArenaFeel)
require(script.Parent.Parent.Animal.AnimalOverhead)
require(script.Parent.Parent.Animal.SlotMath)
```

(`ArenaBattleService.lua:80-85`.)

### `ServerScriptService/Arena/ArenaProgressionService.lua`

```lua
require(ReplicatedStorage.Config.World.Arena)
require(ReplicatedStorage.Utility.Debug)
```

(`ArenaProgressionService.lua` header.)

### `ReplicatedStorage/Config/World/Arena.lua`

```lua
-- Only inside ValidateLive(); lazy so the module stays leaf-loadable:
require(script.Parent.Parent.Creatures.Animals)
```

(`Arena.lua:1309`. Resolves to `ReplicatedStorage.Config.Creatures.Animals`.)

### `ReplicatedStorage/Config/World/ArenaFeel.lua`

No requires.

---

## Other Systems Required

The Arena modules do **not** `require` the other services — they are injected
at boot through `Set*Service()` setters. That is what keeps the dependency
graph acyclic (no service ever requires the Arena back).

| System | Injected as | Used for | Optional? |
|---|---|---|---|
| **PlayerData** (`PlayerService`) | `ArenaService.SetPlayerService` / `ArenaProgressionService.SetPlayerService` | Profile access (`GetPlayerData`). | **Required** — progression reads and writes the profile. |
| **BasesAndSlots** (`BaseService`) | `ArenaService.SetBaseService` | `GetBaseByOwner`, `GetAllBases` — the base's battle area and the Adventurer host. | **Required** for a raid to start. |
| **BasesAndSlots** (`SlotService`) | `ArenaService.SetSlotService` | `SnapshotBaseSlots` — resolving the team. | **Required** for a raid to start. |
| **Animals** (`AnimalService`) | `ArenaService.SetAnimalService`, `ArenaBattleService.SetAnimalService` | `Get` / `GetTemplate` / `AddXP` — combat models and the animal XP award. | **Required** for the XP award; models fall back to the template pipeline. |
| **Inventory** (`SlotMath`) | `require`d directly | `FeetOffsetBelowPrimary`, `StandingCFrameOnSlot` — placing combat models on the arena floor. | Required for correct model placement. |
| **Animals** (`AnimalOverhead`) | `require`d directly | `Refresh`, `EnsureForAnimal`, `RemoveForAnimal` — the floating HP overhead on combat models. | Optional — the overhead is cosmetic. |
| **Economy** (`EconomyService`) | `ArenaService.SetEconomyService` | `TrySpendMoney` (restart prices), `AddMoney` (raid payout), `GetMoney`. | **Required** for paid restarts and for rewards to land. |
| **Carry** (`CarryRegistry`) | `ArenaService.SetCarryRegistry` | Carry-state check at start — you cannot start a raid while carrying something. | Required for the start validation to be correct. |
| **Stealing** (`StealService`) | `ArenaService.SetStealService` | Steal-state check at start. | Required for the start validation to be correct. |
| **Analytics** (`FunnelService`) | `require`d directly | `LogStep`, `IsArenaMilestone` — funnel events. | **Optional** — leaf module, never gameplay-critical. |
| **Tutorials** (`TutorialSignals`) | `require`d directly | `Fire` — `ArenaStarted` / `ArenaCancelled` / `ArenaEnded`. | **Optional** — the bus never throws. |
| **PlayerLogging** (`PlayerLogger`) | `require`d directly | `LogMilestone` — completion monitoring. | **Optional** — leaf module, never gameplay-critical. |
| **SharedUtilities** (`Config.Systems.Debug`) | via `ReplicatedStorage.Utility.Debug` | Gates all Arena telemetry. | Optional, but you will want it on while debugging. |
| **ClientPresentation** | — | The Arena **menu, hit presentation, camera impacts, and result card**. | **Required in practice** — see the note below. |
| **Shared** (`ReplicatedStorage.Utility.ArenaUIState`) | — | The screen-lifecycle coordinator the client modules share. | Required in practice. |

> **The Arena system has no client code of its own.** `ArenaController`,
> `ArenaHitPresentation`, `ArenaCameraImpacts`, and `ArenaResultController`
> live in the **ClientPresentation** system, and `ArenaUIState` lives in
> `ReusableSystems/Shared/CommonModules/`. Copying only `Systems/Arena/`
> gives you a server that fights correctly and renders nothing.

---

## Remotes

Remotes are created at boot from the `Remotes.Names` registry — see
`Shared/CommonModules/Remotes.lua`. **Do not hand-author them.**

| Remote | Direction | Payload |
|---|---|---|
| `ArenaAction` | C→S | `{ Action: 'Open' \| 'Start' \| 'StartRaid' \| 'Cancel', Option?: 'Buy1' \| 'Buy2' \| 'Buy3' }`. The ONLY client input. Loadout, stage, HP, and rewards are never accepted — the server re-resolves them. |
| `ArenaState` | S→C | `{ Progression, Levels, Session?, Loadout?, LastRaid?, Restart, Dialogue, Show? }`. Full snapshot, pushed on open and after every mutation. |
| `ArenaResult` | S→C | `{ Action, Success, Error?, SessionId?, RaidComplete?, Outcome? ('Victory'\|'Defeat'), Stage?, MaxStage?, EarnedCash?, EarnedXP?, HighestClearedWave?, Animals?, Eggs?, StartLevel? }`. `Action` is `'Start'`, `'Cancel'`, or `'RaidEnd'`. Each `Animals` row carries `CombatModel` — the captured actual combat-model clone from `ReplicatedStorage.ArenaResultModels/Session_<id>`. |
| `ArenaCombatEvent` | S→C | `{ Event, SessionId, AttackIndex, AttackSequence, OwnerUserId, ... }`. `ArenaHit` packets are broadcast to **every** client (`FireAllClients`); all other events are owner-targeted. Never trusted inbound; never drives the sim. |

The `ArenaCombatEvent` payload fields are documented in
`Shared/CommonModules/Remotes.lua:180-195`.

---

## Profile Schema

The Arena owns exactly one sub-table of the player profile: `Data.Arena`.

| Key | Type | Default | Owner | Meaning |
|---|---|---|---|---|
| `Arena.Level` | number | `1` | ArenaProgressionService | The player's **arena XP** level. Separate from animal levels. |
| `Arena.XP` | number | `0` | ArenaProgressionService | Arena XP toward the next arena level. |
| `Arena.Wins` | number | `0` | ArenaProgressionService | Lifetime cleared stages. |
| `Arena.HighestCompleted` | number | `0` | ArenaProgressionService | Highest stage ever **cleared**. Drives first-clear vs repeat cash. |
| `Arena.LastReached` | number | `0` | ArenaProgressionService | Highest stage ever **reached**. Monotonic. Drives the paid-restart start stage. |
| `Arena.PendingEggs` | array | `{}` | ArenaProgressionService | Egg rewards pending delivery. **Not consumed by this system.** |

> **There is no `Arena.LastLevel` profile field.** "LastLevel" is the
> *concept* the restart resolvers (`Arena.RestartWarmupLevel` /
> `Arena.RestartDirectLevel`) take as input. The persisted field is
> `Arena.LastReached`, read live through `GetLastReached`
> (`ArenaService.lua:1227`). `LastLevel` appears only as a **key in the
> `Restart` block of the `ArenaState` payload**
> (`buildRestartInfo`, `ArenaService.lua:3033`) and it is
> `max(1, LastReached)` — a display floor, not a stored value.

The arena XP curve is `ArenaConfig.XPRequired(playerLevel)` =
`floor(5 * 1.25 ^ (playerLevel - 1) + 0.5)`. It is deliberately **not** the
animal 1.12 curve.

**Profile fields the Arena reads but does not own:** `Money` (via
`EconomyService`, not directly), `Brainrots` (via `AnimalService` for the
team's stats and models).

---

## DataStore

The Arena does **not** touch the DataStore directly. All persistence goes
through `PlayerService` / `ProfileService` in the **PlayerData** system.

---

## Required Studio Assets

### Per base — required

```text
<BaseFolder>/
  Adventurer              -- Model or BasePart. The prompt host. Alias: Adv.
  Arena/                  -- Folder. The battle area.
    Center                -- optional: the area's discovery marker
    PlayerSpawns/
      Position1           -- BasePart | Attachment | Model
      Position2
      Position3
    EnemySpawns/
      Position1           -- BasePart | Attachment | Model
      Position2
      Position3
```

- The spawn markers are read by `ArenaBattleService.ResolveBattlePositions`
  (`:1014`). A `BasePart` uses its `CFrame`; an `Attachment` uses its
  `WorldCFrame`; a `Model` uses its `GetPivot()`.
- Missing markers fail the battle start **loudly** — `ResolveArenaArea`
  returns `missing = { 'Arena/PlayerSpawns/Position3' }` etc.
- You need **at least `MaxTeamSize` (3)** player spawns and as many enemy
  spawns as the biggest enemy team in your catalog.
- `BossSpawn` is reserved but unused in V1 — bosses take `EnemySpawns` slots.

### Per base — optional

If neither `Adventurer` nor `Adv` exists, `ArenaService.EnsureAdventurer`
creates a **temporary code-built NPC** (a 2×5×2 "Bright blue" brick with a
billboard and a 5s START-button self-heal backstop), marked with the
attribute `ArenaTemporary = true`. It is reused across assignments and never
duplicated. Author the real NPC for a shipped game.

### Global — created by code

| Path | Created by | Purpose |
|---|---|---|
| `Workspace.ArenaBattles` | `battleRootFolder()` (`ArenaBattleService.lua:1184`) | The live battle models. `Battle_<N>.Arena_Player<M>` / `Arena_Enemy<M>`. |
| `ReplicatedStorage.ArenaResultModels` | `keepsakeRoot()` (`ArenaBattleService.lua:2044`) | The keepsakes. `Session_<sessionId>/`. |

### Global — required for the client presentation (ClientPresentation system)

| Path | Purpose |
|---|---|
| `ReplicatedStorage.Assets.Vfx.HitVfx.Attack1` | The hit VFX. Mirrored from ServerStorage by `bootstrap.server.lua:591` (`mirrorArenaHitAssets`). |
| `ReplicatedStorage.Assets.Arena.Sfx.Attack1..3` | The three hit sounds. Mirrored by the same function. |
| `ServerStorage.Assets.Vfx.HitVfx.Attack1` | The authoritative source of the VFX (LocalScripts cannot read ServerStorage). |
| `ServerStorage.Assets.Arena.Sfx.Attack1..3` | The authoritative source of the sounds. |

Missing sources **degrade gracefully** — the client still shows the damage
number and the camera shake, just without the VFX/sound.

### Animal models

Combat models are cloned by `AnimalService`:

- **Preferred**: `cloneLiveAnimalModel` — the player's actual live animal
  model, so the keepsake is the real model.
- **Fallback**: `cloneTemplateModel(rarity, definitionId, trait)` — the
  canonical template pipeline, including the combatant's trait.

Both come from the **Animals** system. You do not author arena-specific
models.

---

## External APIs

| API | Use | Permissions |
|---|---|---|
| `Players` | Player lifecycle, `GetPlayerByUserId` | — |
| `RunService.Heartbeat` | The single centralized combat scheduler | — |
| `Workspace` | Battle models, spawn markers, the live animal models | — |
| `TweenService` | Travel / return tweens | — |
| `Debris` | Keepsake TTL backup (180s) | — |
| `DataStoreService` | **Not used directly.** Persistence is via `PlayerService` / ProfileService in the PlayerData system. | — |

No HTTP. No Marketplace. No webhooks. No credentials of any kind are
required by this system.

If you add analytics that need a webhook or an API key, keep the key in a
**server-side config module** (never in the client, never in this library),
and read it from an environment variable or a Roblox secret rather than
committing it.

---

## Initialization Order

From the source game's `bootstrap.server.lua`:

```text
0.  The Remotes folder must already exist (Remotes.GetFolder()).
    ArenaService.Init() does WaitForChild on ArenaAction with a 10s timeout.

1.  ArenaProgressionService.SetPlayerService(PlayerService)      -- :524
2.  ArenaService.SetPlayerService(PlayerService)                 -- :525
3.  ArenaService.SetBaseService(BaseService)                     -- :526
4.  ArenaService.SetAnimalService(AnimalService)                 -- :527
5.  ArenaService.SetSlotService(SlotService)                     -- :528
6.  ArenaService.SetCarryRegistry(CarryRegistry)                 -- :529
7.  ArenaService.SetStealService(StealService)                   -- :530
8.  ArenaService.SetNotificationService(NotificationService)     -- :531
9.  ArenaService.SetProgressionService(ArenaProgressionService)  -- :532
10. ArenaService.SetEconomyService(EconomyService)               -- :533
11. ArenaService.SetBattleService(ArenaBattleService)            -- :534
12. ArenaBattleService.SetAnimalService(AnimalService)           -- :535
13. ArenaService.Init()                                          -- :536
```

`Init()` must come **last**: it reads `battleServiceRef` to install the
validator / end / cancel / event callbacks (`:3285`) and asserts on the
`ArenaAction` remote (`:3385`).

### Per-player hooks

```text
On base assignment:   ArenaService.EnsureAdventurer(base)                      -- :906 (pcall'ed)
On player ready:      ArenaProgressionService.NormalizeArena(profile)          -- :966 (pcall'ed)
On player leave:      ArenaService.ForgetPlayer(userId)                        -- :1253 (pcall'ed)
```

`NormalizeArena` on load lets older saves gain
`{ Level = 1, XP = 0, Wins = 0 }` without touching any other field.

### Asset mirroring (SharedUtilities bootstrap)

```text
mirrorArenaHitAssets()   -- bootstrap.server.lua:688
  ServerStorage.Assets.Vfx.HitVfx.Attack1
    -> ReplicatedStorage.Assets.Vfx.HitVfx.Attack1
  ServerStorage.Assets.Arena.Sfx.Attack1..3
    -> ReplicatedStorage.Assets.Arena.Sfx.Attack1..3
```

Check-then-create: a Studio-authored mirror is **never** overwritten.

---

## Slot Namespace

Arena stands live in the same slot-id format as normal slots, but in a
separate index namespace:

| Space | Index range | Id example |
|---|---|---|
| Normal slots | `1 .. 99` | `p7:<userId>:slot:3` |
| Arena stands | `1000 .. 1099` | `p7:<userId>:slot:1001` |

`SlotType.ArenaSlotIndexBase = 1000`, `SlotType.MaxArenaStands = 99`
(`Shared/Types/SlotType.lua:70-71`). The scope lives on the slot record
(`slot.arena`), **never** in the id.

---

## Transaction Reasons

`ReplicatedStorage.Types.TransactionReason` (all already in the accepted
set — no changes needed):

| Constant | Value | Used when |
|---|---|---|
| `ArenaReward` | `'ArenaReward'` | The raid payout (`AddMoney`, with `ApplyMultiplier = false`). |
| `ArenaRestart` | `'ArenaRestart'` | Paying for a `Buy1` / `Buy2` restart. |
| `ArenaRestartRefund` | `'ArenaRestartRefund'` | Refunding a restart when the start fails after the charge. |

---

## Related

- [README.md](README.md) — what the system does, entry points, files.
- [MEMORY.md](MEMORY.md) — step-by-step mechanics, invariants, gotchas.
- [API.md](API.md) — every public function.
- [Setup.md](Setup.md) — install into a new Rojo project.
- [Config.lua](Config.lua) — the consolidated tunable mirror.
