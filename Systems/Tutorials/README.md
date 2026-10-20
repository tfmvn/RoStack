# Tutorials

Server-authoritative first-time-player onboarding: a thin **guide
layer** over the real game systems. It implements **no gameplay** —
it observes committed actions through a signal bus and advances one
active step per player.

**Portability:** Grade A core (the pure state machine, the resume
derivation, the per-player tagging scheme) + Grade B (the exact step
chain, the signal channel names, and the Beam asset id). See
*Portability* below.

**Source game:** Brainrot Arena (`p-7`).

---

## What It Does

```
  GAMEPLAY SYSTEM                TUTORIAL LAYER                 CLIENT
  (owns the rules)               (observes only)                (renders only)
       |                              |                             |
       | TutorialSignals.Fire(...)   |                             |
       |----------------------------->|                             |
       |   "EggPurchased",           | NextStep(state, event)     |
       |    "AnimalPlaced", ...       |   (pure transition table)   |
       |                              |          |                  |
       |                              |          v                  |
       |                              |   _active[userId] = {Step,  |
       |                              |                 EggId,      |
       |                              |                 AnimalId}    |
       |                              |          |                  |
       |                              |          v                  |
       |                              |   CollectionService tag     |
       |                              |   'TutorialTarget_<userId>' |
       |                              |          |                  |
       |                              |          v                  |
       |                              |   TutorialState RemoteEvent |
       |                              |---------------------------->|
       |                              |                             | draws beam,
       |                              | <-- TutorialAction {        | arrow, HUD
       |                              |      'State'|'Continue'|    |
       |                              |      'Skip' } ------------|
```

The design in one sentence: **the tutorial never implements a rule, it
only observes committed outcomes and gates the one client intent that
can advance the chain (`Continue`).**

### The step chain

```
BuyEgg -> WaitForEgg -> HatchEgg -> PickUpAnimal -> PlaceAnimal
       -> StartArena -> ArenaStarted -> ArenaEnded
       -> UpgradeAnimal -> LockBase -> Completed
```

Eleven steps, exactly one active per player, `Completed` is terminal.

### The identity chain

The tutorial never points at "a nearby egg" — it tracks the player's
**actual** objects:

```
the purchased egg id  ->  the hatched animal id
   ->  that animal in an arena slot  ->  that player's arena session
   ->  that animal upgraded  ->  that player's base locked
```

Every transition validates the tracked id against the event payload. A
mismatched id is ignored.

### The only client intent

`Continue` is the only action that moves the chain forward, and it is
**server-gated**: it is accepted only while the server itself holds
the `ArenaEnded` step for that player. `State` just re-publishes the
snapshot. `Skip` terminates the tutorial early (and is recorded as a
*skip*, not a completion).

---

## Entry Points

| Entry point | Kind | Notes |
|---|---|---|
| `TutorialService.Init()` | Server | Connects the ten signal channels, binds the `TutorialAction` remote, publishes the Beam template. Idempotent. |
| `TutorialService.Start()` | Server | Starts the 1 Hz recovery sweep over active tutorial players. Idempotent. |
| `TutorialService.ResumeForPlayer(player)` | Server | Join entry. Reads the persisted state, validates it against the live registries, publishes. |
| `TutorialService.HandleAction(player, payload)` | Server | The `TutorialAction` handler: `'State'` / `'Continue'` / `'Skip'`. |
| `TutorialService.RecoverFor(userId)` | Server | Re-validate a player's tracked ids against the live registries and repair the step. |
| `TutorialService.PublishTo(target)` | Server | Push a `TutorialState` snapshot to a player (accepts a `Player` or a `userId`). |
| `TutorialService.GetStep(userId)` | Server | The current step string, or `nil`. |
| `TutorialService.GetState(userId)` | Server | `{ Step, EggId, AnimalId }`, or `nil`. |
| `TutorialService.ForgetPlayer(userId)` | Server | Drop the runtime state and the player's tag. |
| `TutorialService.NextStep(state, event)` | Server (pure) | The transition table. **The heart of the system.** |
| `TutorialService.DeriveResume(persisted, lookup)` | Server (pure) | Derive a resume state from the persisted state plus live lookups. |
| `TutorialService.TagFor(userId)` | Server (pure) | `'TutorialTarget_<userId>'`. |
| `TutorialService.BeamAssetId()` | Server (pure) | The InsertService asset id (`14403995847`). |
| `TutorialService.StarterEggRarity()` | Server (pure) | The canonical starter egg rarity for every new player. |
| `TutorialSignals.Fire(name, payload)` | Server | Publish a gameplay event on the bus. Called by the gameplay systems. |
| `TutorialSignals.Connect(name, fn)` | Server | Subscribe to a channel. |
| `TutorialService._TestSetState(userId, state?)` / `_TestReset()` | Test seam | Inject / clear runtime state. |
| `TutorialSignals._TestReset()` | Test seam | Drop all channels. |

---

## Files

| Library path | Roblox destination | Purpose |
|---|---|---|
| `Source/ServerScriptService/Tutorial/TutorialService.lua` | `ServerScriptService.Tutorial.TutorialService` | The state machine, the tag/publish layer, the recovery sweep. |
| `Source/ServerScriptService/Tutorial/TutorialSignals.lua` | `ServerScriptService.Tutorial.TutorialSignals` | The named event bus the gameplay systems fire into. |

The client half (`TutorialController`) lives in the **ClientPresentation**
system, not here.

---

## Configuration

There is **no config module of its own.** The tunables are literals:

| Value | Lives in | Default | Meaning |
|---|---|---|---|
| `TutorialService.TAG` | `TutorialService.lua:74` | `'TutorialTarget'` | The **prefix** of the per-player CollectionService tag. |
| `TutorialService.BeamAssetId()` | `TutorialService.lua:90` | `14403995847` | The InsertService asset id for the tutorial Beam template. |
| Recovery sweep period | `TutorialService.lua:1060` | `1` second | How often `RecoverFor` runs for each active player. |
| Idle poll | `TutorialService.lua:1062` | `0.5` s | The `Signals`/`Heartbeat` idle cadence (the sweep accumulates `dt` and fires at 1 Hz). |
| `SlotType.ArenaSlotIndexBase` | `ReplicatedStorage.Types.SlotType` | `1000` | The arena-slot index offset used by `_isArenaSlotId`. |

Two external values are read:

| Value | Lives in | Meaning |
|---|---|---|
| `EggConfig.GetStarterRarity()` | `ReplicatedStorage.Config.Creatures.Eggs` | The canonical starter egg rarity. **Absent in this codebase** — see *Known Limitations*. |
| `RarityDefs.Order[1]` | `ReplicatedStorage.Config.Creatures.Rarity` | The fallback: `'Common'`. |

The `SlotType` module also exposes `State.Empty` (`'Empty'`), used by
the arena-slot suggestion.

---

## Dependencies

See `Dependencies.md` for the full list.

Module requires at load:

- `script.Parent.TutorialSignals`
- `ReplicatedStorage.Types.SlotType`
- `ReplicatedStorage.Utility.Remotes`
- `ReplicatedStorage.Utility.Debug`
- `ReplicatedStorage.Config.Creatures.Eggs`
- `ReplicatedStorage.Config.Creatures.Rarity`
- `script.Parent.Parent.FunnelService` (Analytics)
- `script.Parent.Parent.PlayerLogger.PlayerLogger` (PlayerLogging)

Lazy service refs, resolved on first `_services()` call and cached:

- `ServerScriptService.PlayerService`
- `ServerScriptService.Egg.SpawnService`
- `ServerScriptService.AnimalService`
- `ServerScriptService.Base.SlotService`
- `ServerScriptService.BaseService`
- `ServerScriptService.Base.BaseLockService` (only inside
  `RecoverFor`)

Roblox services: `Players`, `CollectionService`, `RunService`,
`ReplicatedStorage`, `InsertService` (Beam template only).

---

## Initialization Order

```text
1. createRemotes()                  -- TutorialAction + TutorialState must exist
2. PlayerService.Init()
3. TutorialService.Init()           -- connects the signal channels,
                                     -- binds TutorialAction.OnServerEvent,
                                     -- spawns the Beam template fetch
4. TutorialService.Start()          -- starts the 1 Hz recovery sweep
5. On player join (AFTER the profile has loaded and the base has
   been restored):
      TutorialService.ResumeForPlayer(player)
```

Step 5 **must** run after the profile load. `ResumeForPlayer` reads
`profile.Tutorial` and validates it against the live egg/animal
registries; running it earlier would derive the wrong step.

`Init()` and `Start()` are both idempotent.

---

## Data

### Persisted (the gameplay profile)

`profile.Data.Tutorial = { Completed: boolean, Step: string, EggId: string?, AnimalId: string? }`

Written through `PlayerService.SetTutorial(userId, {...})`, read
through `PlayerService.GetPlayerData(userId).Tutorial`.

`Completed` is derived, not stored independently:
`Completed = (state.Step == 'Completed')`.

### In-memory

| Table | Key | Value | Cleared by |
|---|---|---|---|
| `_active` | `userId` | `{ Step, EggId, AnimalId }` | `ForgetPlayer`, `_TestReset`, and on completion (`_active[userId] = nil`) |
| `_taggedByUser` | `userId` | the tagged `Instance` | `ForgetPlayer`, `_untagPlayer`, `_TestReset` |
| `_tickAccum` | — | the sweep's fractional second accumulator | reset each tick |
| `_started` / `_tickConn` | — | boot guards | — |

### The signal bus

`TutorialSignals._channels[name]` — a `Signals.new()` object per
channel name, created lazily.

### The CollectionService tags

One tag per active player: `'TutorialTarget_<userId>'`, applied to
**that player's** tracked egg or animal model. Tags are **never**
globally cleared — untagging is scoped to the acting player's own
previous target.

---

## Known Limitations

- **`EggConfig.GetStarterRarity` does not exist** in this codebase.
  `TutorialService.StarterEggRarity()` calls it inside a `pcall`, so
  the call fails silently and the function falls back to
  `RarityDefs.Order[1]` = `'Common'`. The **result is still correct
  today** (Common is the cheapest egg at 100), but the "never
  hardcoded, read from the config" contract is not actually
  satisfied — the value comes from the rarity *display order*, not
  from a price scan. If the rarest egg ever became the cheapest, the
  two would disagree.
- **The shipped spec fails on that same call.** Line 581 of
  `Tests/TutorialService.spec.lua` calls `Eggs.GetStarterRarity()`
  directly, which errors with "attempt to call a nil value". The
  spec therefore cannot pass until the config helper is added (or the
  assertion is changed).
- **The Tutorials spec cannot run standalone.** It requires
  `StarterPlayer.StarterPlayerScripts.TutorialController`, which
  lives in the **ClientPresentation** system. You must copy both
  systems (or the whole client half) to run it.
- **`_isArenaSlotId` is a local heuristic.** It parses the trailing
  `:N` of the slot id and compares it with
  `SlotType.ArenaSlotIndexBase` (1000). The comment notes there is no
  `SlotType.IsArenaSlot` helper, so the rule lives next to its only
  consumer. A slot id that does not end in `:<digits>` is never an
  arena slot.
- **The recovery sweep is O(active players) per second** and each
  `RecoverFor` does several registry lookups. It is registry lookups
  by id — never a Workspace scan — but it is not free.
- **`RecoverFor` can fall all the way back to `BuyEgg`** from a later
  step. The code logs a loud `Debug.Warn` when that happens
  ("must stay exceptional"), but it is a real possibility if the
  tracked egg and animal both vanish.
- **The `ArenaCancelled` transition goes backwards** —
  `ArenaStarted → StartArena`. That is intentional (the arena was
  cancelled, so the player must start it again) but it means the
  chain is not strictly monotonic in that one case.
- **The tutorial's own audio is the client's job.** The server never
  calls `:Play()` on tutorial audio; the client plays the step sting
  once per real step change on the `TutorialState` push. A design
  that mounts a server-side `PlayerGui` clone was deleted.
- **The Beam template needs `InsertService`.** It is fetched at
  `Init()` in a `task.spawn` so it never stalls boot. If the asset is
  private, deleted, or the wrong type, the load error is printed
  verbatim and the client falls back to a white beam it builds
  itself.
- **`TutorialService.Init()` binds the remote with two 10-second
  `WaitForChild` calls.** If `TutorialAction` never appears, the
  tutorial silently never accepts client intents.
- **The `Skip` action is a real completion.** It persists
  `Completed = true` and is logged to the funnel as
  `TutorialSkipped` — but it is **not** logged to `PlayerLogger` as a
  milestone. A skipped tutorial never appears in Discord.
- **`_publishBeamTemplate` does not re-publish.** If
  `ReplicatedStorage.TutorialBeamTemplate` already exists, it
  returns immediately. There is no refresh path.

---

## Testing

`Tests/TutorialService.spec.lua` — **40 cases** in five groups.

*Steps* — exactly one terminal state, the full happy chain on exact
identity matches, wrong ids / wrong slots / wrong steps ignored, the
arena-cancel revert and the `Continue` gate on `ArenaEnded`, and the
regression that a hatch advances to `PickUpAnimal` and **never** back
to `BuyEgg`.

*`DeriveResume`* — `Completed` stays terminal, fresh buyers start at
`BuyEgg`, an already-owned unhatched egg is adopted instead of
repeating `BuyEgg`, live tracked eggs are kept, the mid-hatch
`Opening` egg with a destroyed model stays in `HatchEgg`, and the
service never invents animals.

*`TutorialController` text map* — every active step maps to prompt
text, the Beam asset id is pinned, the Studio-authored `HUD.Tutorial`
label is found without creating UI, the white fallback beam and its
named attachments are built, a late-replicating asset upgrades the
fallback, the checklist is derived from the internal steps, the skip
intent payload is the gated server action, sound templates resolve
from an injected root, and the typewriter aborts stale tasks.

*Spotlight + beats* — UI-open instruction beats are timed without
hardcoded paths, the real button is spotlighted and restored on
teardown, an authored `UIScale` is reused, switching buttons tears
down the old spotlight, the `RightSide` chain is lifted, and the
spotlight pivots to the button centre.

*Multiplayer egg targeting* — the starter rarity comes from the
config, the tags are per-player, the `BuyEgg` prompt names the
starter egg, two players track their own egg ids, `DeriveResume`
restores each player from their own persisted egg, and the `BuyEgg`
target is starter-only / prompt-gated / container-scoped /
purchaser-aware.

**Known problem:** the spec requires `StarterPlayer.StarterPlayerScripts.TutorialController`
(from the ClientPresentation system) and calls
`Eggs.GetStarterRarity()`, which does not exist. See *Known
Limitations*.

Run it with the TestEZ runner. See `../../Tests/README.md`.

---

## Portability

**Grade A — portable core**, with a **Grade B** content/adapter layer.

**Grade A (portable as-is):**
- `TutorialService.NextStep` — the pure transition function. Copy it
  and change the table.
- `TutorialService.DeriveResume` — the pure resume derivation. The
  `lookup` interface (`eggById`, `ownedUnhatchedEggId`, `animalById`)
  is injected, so the function is already decoupled.
- The per-player tagging scheme (`TagFor`) and the scoped untagging.
- The `publish`/`recover`/`resume` lifecycle, the `_services()` lazy
  resolution (cycle-free by construction), the `pcall` discipline.
- `TutorialSignals` — the whole bus is generic.

**Grade B (game-specific adapter — must be rewritten):**
- The step chain names (`BuyEgg`, `WaitForEgg`, …) and the exact
  transition table.
- The ten signal channel names and their payload shapes.
- The Beam asset id and the `InsertService` template approach.
- The `SlotType.ArenaSlotIndexBase` arena-slot heuristic.
- The `profile.Data.Tutorial` shape and the `PlayerService` contract
  (`GetPlayerData`, `SetTutorial`).
- The `PlayerService.GetPlayerData` field names the snapshot reads
  (`Rebirth`, `Arena.Level`, `Arena.Wins`, `Tutorial.Completed`) —
  those belong to PlayerLogging, not here.
- The `LuckyBlocks` rows and the egg states
  (`'Available'`, `'Traveling'`, `'Placed'`) that the
  `ownedUnhatchedEggId` lookup checks.

**Grade C (platform-bound):** none. `InsertService` is used for one
optional asset, and the client falls back when it is unavailable.

---

## Adapting to a New Game

1. **Redraw the chain.** Edit `TutorialService.Step` and the
   `NextStep` table together. The table is exhaustive — anything not
   listed returns `nil` and changes nothing.
2. **Rename the signal channels** to match your gameplay events, and
   update both the `channels` list in `Init()` and the `name ==`
   branches in `NextStep` and `_onBusEvent`.
3. **Fire the signals from your gameplay services.** Fire exactly
   once per **committed** action, and include the ids the tutorial
   must track (`EggId`, `AnimalId`, `SlotId`, `BaseId`).
4. **Replace the arena-slot heuristic** with your own
   `SlotType.IsArenaSlot` helper if you have one.
5. **Add `GetStarterRarity()` to your egg config** (a price scan) so
   the starter rarity is genuinely derived, not taken from the
   display order.
6. **Add a client controller** that listens for `TutorialState`,
   reads the `TutorialTarget_<userId>` tag, and draws the beam. The
   ClientPresentation system's `TutorialController` is the reference
   implementation.
7. **Keep `Continue` server-gated.** Never trust a client intent to
   advance the chain on its own.
8. **Keep the recovery sweep.** Without it, a player whose egg model
   is destroyed mid-hatch loses their tutorial target.
