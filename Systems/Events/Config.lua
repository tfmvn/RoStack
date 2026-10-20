--!strict
--[[
	Events — consolidated tunables (REFERENCE MODULE)

	=====================================================================
	THIS FILE IS DOCUMENTATION, NOT LIVE CONFIGURATION.
	=====================================================================

		The LIVE config for this system is already part of the system:

			ReplicatedStorage/Config/World/Events.lua

		That file is in this system's `Source/` tree, at its original
		Roblox path, and it is what `EventService`,
		`EnvironmentModifier` and `EventLights` actually read.

		TO CHANGE A VALUE: edit `Source/ReplicatedStorage/Config/World/Events.lua`.
		Editing this file changes nothing at runtime.

		Why this file exists: `Events.lua` is a 562-line module that
		mixes the event catalog, the scheduler, the transition
		cinematic and the luck-pool order. This file is the
		single-screen answer to "what can I tune, and what breaks if
		I change it?" — every tunable is listed below with its
		default, meaning, valid range, safety, and which module
		reads it.

		The live config is registered with the central validator as one
		domain:
			World.Events
		It exposes `Validate(): { string }` and returns an empty
		array when clean. A Studio boot with a validation failure is a
		hard error; a live server only warns.
]]

local Config = {}

-- =====================================================================
-- Scheduler
-- =====================================================================

--[[
	Scheduler.CycleSeconds

		Default:  300  (5 minutes)
		Meaning:  The seconds between special-event opportunities.
		          At the end of every cycle the server rolls once
		          over the weighted catalog; the winner (or "no
		          event") is PRE-DECIDED and published so the UI can
		          count down to it.
		Range:    >= 10 (the validator rejects anything lower; the
		          engine also falls back to 300 if the value is
		          missing or < 10).
		Safe to change:  YES. It is a pure pacing value. Note that
		          the cycle boundary is NOT aligned across servers —
		          each server schedules from its own
		          `_serverNow()`, so two servers drift.
		Read by:  EventService.ScheduleNext
		Placeholder:  NO
]]
Config.SCHEDULER_CYCLE_SECONDS = 300

--[[
	Scheduler.NoneWeight

		Default:  60
		Meaning:  The implicit "no special event this cycle" weight.
		          It is NOT an event — it is the leftover bucket
		          after the enabled events' weights. With the
		          current 20/20/60 split that is Galaxy 20%,
		          Snowfall 20%, normal cycle 60%.
		Range:    >= 0 (the validator rejects a negative value; the
		          engine treats 0 as "no normal bucket").
		Safe to change:  YES. The effective probability of each
		          event is `Weight / (sum(weights) + NoneWeight)`,
		          so changing this rescales ALL of them. The
		          weighted-roll spec expectations
		          (0.19 -> Galaxy, 0.2 -> Snowfall, 0.4 -> nil)
		          depend on the exact totals.
		Read by:  EventService.PickNextEventId
		Placeholder:  NO
]]
Config.SCHEDULER_NONE_WEIGHT = 60

--[[
	Order

		Default:  { 'Galaxy', 'Snowfall' }
		Meaning:  The DETERMINISTIC scheduler iteration order. The
		          weighted roll walks this list, so the probability
		          boundaries depend on it. `pairs()` order is not
		          guaranteed, which is why the roll does not use it.
		Range:    a non-empty array of unique, non-empty event ids.
		          It must NOT contain 'Base' (Base is never
		          scheduled), and every id must have an
		          `Events.Events[id]` entry.
		Safe to change:  YES, but the spec's roll expectations
		          change if you reorder or change the weights.
		Read by:  EventService.PickNextEventId
		Placeholder:  NO
]]
Config.ORDER = { 'Galaxy', 'Snowfall' }

-- =====================================================================
-- Transition cinematic
-- =====================================================================

--[[
	Transition.FovMultiplier

		Default:  0.83
		Meaning:  The camera FOV multiplier during the flash. The
		          base FOV of 70 becomes ~58. RELATIVE — the live
		          FOV is captured per player and restored exactly,
		          never assumed.
		Range:    0 < x < 1 (the validator rejects anything else;
		          the engine's defensive fallback also requires
		          0 < x < 1).
		Safe to change:  YES, but keep it strictly below 1 — a
		          value of 1 is not a zoom.
		Read by:  EventService._transitionTimings, and the client's
		          EventTransitionController
		Placeholder:  NO
]]
Config.TRANSITION_FOV_MULTIPLIER = 0.83

--[[
	Transition.FovSeconds

		Default:  0.35
		Meaning:  The FOV zoom duration, with smooth easing.
		Range:    >= 0.
		Safe to change:  YES.
		Read by:  EventService._transitionTimings
		Placeholder:  NO
]]
Config.TRANSITION_FOV_SECONDS = 0.35

--[[
	Transition.FlashDelaySeconds

		Default:  0.05
		Meaning:  How long after the FOV zoom begins the white
		          flash starts building. The FOV LEADS, the flash
		          follows.
		Range:    >= 0.
		Safe to change:  YES, but it is part of the CoverSeconds
		          floor (see below).
		Read by:  EventService._transitionTimings
		Placeholder:  NO
]]
Config.TRANSITION_FLASH_DELAY_SECONDS = 0.05

--[[
	Transition.FlashInSeconds

		Default:  0.3
		Meaning:  Transparent -> fully white.
		Range:    > 0 (the validator requires a positive value; the
		          engine's fallback also requires > 0).
		Safe to change:  YES, but it is part of the CoverSeconds
		          floor.
		Read by:  EventService._transitionTimings
		Placeholder:  NO
]]
Config.TRANSITION_FLASH_IN_SECONDS = 0.3

--[[
	Transition.HoldSeconds

		Default:  0.3
		Meaning:  The full-white dwell before the server acts. This
		          is a CLIENT-side hold — the client keeps the
		          screen white this long. The SERVER's actual gate
		          is `CoverSeconds`.
		Range:    >= 0.
		Safe to change:  YES, but it is part of the CoverSeconds
		          floor.
		Read by:  the validator (as part of the cover floor) and
		          the client's EventTransitionController. NOTE: the
		          server's defensive fallback table does NOT include
		          it — the server does not need it.
		Placeholder:  NO
]]
Config.TRANSITION_HOLD_SECONDS = 0.3

--[[
	Transition.FadeOutSeconds

		Default:  1
		Meaning:  Fully white -> transparent reveal.
		Range:    > 0.
		Safe to change:  YES.
		Read by:  EventService._transitionTimings
		Placeholder:  NO
]]
Config.TRANSITION_FADE_OUT_SECONDS = 1

--[[
	Transition.CoverSeconds

		Default:  0.65
		Meaning:  The SERVER GATE: the delay between the Prepare
		          broadcast and the world change. The world change
		          happens behind full white.
		Range:    >= 0, AND it must be >=
		          FlashDelaySeconds + FlashInSeconds + HoldSeconds.
		          The validator enforces the second rule. With the
		          shipped values that floor is exactly 0.65, so
		          0.65 is the MINIMUM legal value, not a comfortable
		          margin.
		Safe to change:  YES, but keep the cover floor. Raising it
		          gives clients more time to reach full white;
		          lowering it below the floor makes the world change
		          visible.
		Read by:  EventService._transitionTimings, EventService.StartEvent
		          (the `task.wait`), EventService.EndEvent
		Placeholder:  NO
]]
Config.TRANSITION_COVER_SECONDS = 0.65

-- =====================================================================
-- Event definitions
-- =====================================================================

--[[
	EVENT SHAPE

		Default:  see the `EventDefinition` type in the live config
		Meaning:  ONE shape for every event. Every field is read by
		          the engine; adding an event is a pure data
		          operation with NO engine change.
		Range:    n/a — this is a type contract.
		Safe to change:  the SHAPE, yes, but it is a wide-reaching
		          change: the engine, the validator and the client
		          all read it.
		Read by:  EventService, EnvironmentModifier, EventLights
		Placeholder:  NO
]]
Config.EVENT_SHAPE = {
	Id = 'string',
	Name = 'string',
	DisplayName = 'string',
	DurationSeconds = 'number',
	MutationIntervalSeconds = 'number',
	Scheduling = '{ Enabled: boolean, Weight: number }',
	Assets = '{ FolderName: string }',
	Mutations = '{ [string] = { MutationId: string, Chance: number } }',
	Environment = '{ Colors = { [string] = { Color: Color3, Targets: { string } } } }',
	Lights = '{ Containers: { string } }?',
	Time = '{ Override: boolean, ClockTime: number }',
}

-- ---------------------------------------------------------------------
-- Base — the baseline. NEVER scheduled, NEVER started.
-- ---------------------------------------------------------------------

--[[
	EVENTS.Base

		Default:  { Id = 'Base', Name = 'Normal', DisplayName = 'NORMAL',
		            DurationSeconds = 0, MutationIntervalSeconds = 0,
		            Scheduling = { Enabled = false, Weight = 0 },
		            Assets = { FolderName = '' }, Mutations = {},
		            Environment = { Colors = {} },
		            Time = { Override = false, ClockTime = 14 } }
		Meaning:  The named "normal world state". It exists so every
		          system has a baseline to document and fall back
		          to. It is NEVER scheduled (weight 0, disabled),
		          NEVER started (`IsStartable('Base') == false`), and
		          the validator REJECTS 'Base' appearing in `Order`.
		Range:    `Id` must be exactly 'Base'; `DurationSeconds` and
		          `MutationIntervalSeconds` must be 0;
		          `Scheduling.Enabled` must be false.
		Safe to change:  only `Name` / `DisplayName` / `Time.ClockTime`
		          (the documented default clock, which the engine
		          NEVER applies — the engine restores the actual
		          prior clock from a snapshot).
		Read by:  EventService.GetEvent, IsStartable, PickNextEventId
		          (skipped), the validator
		Placeholder:  NO
]]

-- ---------------------------------------------------------------------
-- Galaxy — night + the Galactic mutation
-- ---------------------------------------------------------------------

--[[
	EVENTS.Galaxy.DurationSeconds

		Default:  180  (3 minutes)
		Meaning:  How long the event runs before the tick ends it.
		Range:    >= 0.
		Safe to change:  YES. Keep it comfortably above
		          MutationIntervalSeconds — an event shorter than
		          the interval NEVER mutates anything (the first
		          cycle lands one full interval after the start).
		Read by:  EventService.StartEvent
		Placeholder:  NO
]]
Config.GALAXY_DURATION_SECONDS = 180

--[[
	EVENTS.Galaxy.MutationIntervalSeconds

		Default:  30
		Meaning:  The progressive mutation cadence. The worker
		          evaluates the currently-eligible eggs every this
		          many seconds while the event is active — 6
		          opportunities in a 180 s run. Mutations are NOT
		          all rolled at the start.
		Range:    >= 5 for a startable event (the validator
		          rejects anything lower so a cycle can never spin).
		Safe to change:  YES.
		Read by:  EventService._tick, EventService.RunMutationCycle
		Placeholder:  NO
]]
Config.GALAXY_MUTATION_INTERVAL_SECONDS = 30

--[[
	EVENTS.Galaxy.Scheduling

		Default:  { Enabled = true, Weight = 20 }
		Meaning:  The weighted-scheduler entry. The effective
		          probability is `Weight / (sum + NoneWeight)`, so
		          with the current values Galaxy is 20%.
		Range:    `Enabled` must be a boolean; `Weight` must be a
		          number >= 0. A weight of 0 (or `Enabled = false`)
		          removes the event from the roll entirely.
		Safe to change:  YES, but the spec's roll expectations
		          (0.19 -> Galaxy) depend on the exact totals.
		Read by:  EventService.PickNextEventId
		Placeholder:  NO
]]
Config.GALAXY_SCHEDULING = { Enabled = true, Weight = 20 }

--[[
	EVENTS.Galaxy.Assets.FolderName

		Default:  'Galaxy'
		Meaning:  The name of the folder under
		          `ServerStorage.Assets.Events` that is CLONED into
		          the Workspace for the event's duration. The clone
		          is renamed `EventAssets_Galaxy` and destroyed on
		          the event end.
		Range:    any non-empty string. An empty string means "no
		          assets" (the apply is skipped).
		Safe to change:  YES, but you must author the matching
		          folder in Studio. A MISSING folder is a WARNING,
		          not an error — the event still runs, just without
		          the assets.
		Read by:  EventService._applyAssets
		Placeholder:  NO — but the ASSETS themselves are
		              Studio-authored and game-specific.
]]
Config.GALAXY_ASSETS_FOLDER_NAME = 'Galaxy'

--[[
	EVENTS.Galaxy.Mutations.Galactic

		Default:  { MutationId = 'Galactic', Chance = 0.8 }
		Meaning:  The mutation this event applies to eligible eggs.
		          `Chance` is a FRACTION in [0, 1], evaluated per
		          mutation (per egg, per cycle) — not once per
		          event.
		Range:    `MutationId` must be a non-empty string that
		          exists in `Config/Creatures/Mutations.lua`;
		          `Chance` must be in [0, 1].
		Safe to change:  YES. An already-mutated egg is NEVER
		          overwritten, so raising the chance is safe.
		Read by:  EventService.TryMutateEgg, EventService.RollMutationChance
		Placeholder:  NO
]]
Config.GALAXY_MUTATION = { MutationId = 'Galactic', Chance = 0.8 }

--[[
	EVENTS.Galaxy.Environment.Colors

		Default:  {}  (empty)
		Meaning:  Galaxy v1 needs no map recolour — the night
		          override plus the assets carry it. The table stays
		          extensible: adding e.g. `Colors.Purple.Targets`
		          just works, with no engine change.
		Range:    a table of `{ Color = Color3, Targets = { string } }`.
		Safe to change:  YES.
		Read by:  EventService._applyEnvironment,
		          EnvironmentModifier.ApplyColors
		Placeholder:  NO
]]
Config.GALAXY_ENVIRONMENT_COLORS = {}

--[[
	EVENTS.Galaxy.Lights.Containers

		Default:  { 'Map.MainIsland.PointLights', 'Base.PointLights' }
		Meaning:  Every `Light` under these containers turns ON for
		          the run, then restores its exact prior `Enabled`
		          state (a light authored ON stays ON).
		Range:    an array of non-empty container path strings.
		          The path convention is the same as the colour
		          targets: 'Map....' from Workspace.Map, 'Base....'
		          inside EVERY player base, '*' as a wildcard.
		Safe to change:  YES. A missing container is a WARNING and
		          is skipped — a lightless place is a silent no-op.
		Read by:  EventService._applyLights, EventLights.ApplyLights
		Placeholder:  NO — but the CONTAINERS are this game's map
		              layout.
]]
Config.GALAXY_LIGHT_CONTAINERS = { 'Map.MainIsland.PointLights', 'Base.PointLights' }

--[[
	EVENTS.Galaxy.Time

		Default:  { Override = true, ClockTime = 0 }
		Meaning:  The night override. `Lighting.ClockTime` is set to
		          0 and RESTORED to the exact pre-event value on the
		          event end (never an assumed default).
		Range:    `Override` must be a boolean; `ClockTime` must be
		          a number in [0, 24]. (The validator's range is
		          inclusive of 24, which is not a valid Roblox
		          ClockTime — prefer 0..23.99.)
		Safe to change:  YES. NOTE: `Lighting.ClockTime` is
		          GLOBAL — it affects the whole place, and it will
		          clobber any other system's clock change made
		          during the event.
		Read by:  EventService._applyTime, EventService._restoreTime
		Placeholder:  NO
]]
Config.GALAXY_TIME = { Override = true, ClockTime = 0 }

-- ---------------------------------------------------------------------
-- Snowfall — day + map recolour + the Frost mutation
-- ---------------------------------------------------------------------

--[[
	EVENTS.Snowfall

		Default:  the same shape as Galaxy —
		            DurationSeconds = 180,
		            MutationIntervalSeconds = 30,
		            Scheduling = { Enabled = true, Weight = 20 },
		            Assets = { FolderName = 'Snowfall' },
		            Mutations = { Frost = { MutationId = 'Frost',
		                                  Chance = 0.8 } },
		            Time = { Override = true, ClockTime = 14 }
		Meaning:  Snowfall is the second scheduled event.
		Range:    see the Galaxy entries above — the constraints are
		          identical.
		Safe to change:  YES.
		Read by:  the same modules as Galaxy
		Placeholder:  NO
]]
Config.SNOWFALL = {
	DurationSeconds = 180,
	MutationIntervalSeconds = 30,
	Scheduling = { Enabled = true, Weight = 20 },
	Assets = { FolderName = 'Snowfall' },
	Mutation = { MutationId = 'Frost', Chance = 0.8 },
	Time = { Override = true, ClockTime = 14 },
}

--[[
	EVENTS.Snowfall.Environment.Colors.Gray

		Default:  Color3.fromRGB(170, 170, 170)
		          Targets = { 'Map.MainIsland.Paths',
		                      'Base.Build.Paths' }
		Meaning:  Greys out the paths, in the island and in every
		          player base.
		Range:    `Color` must be a Color3; `Targets` entries must
		          be dot-separated names with lone-'*' wildcards (no
		          empty segments, no leading/trailing dots, no
		          '..', no multi-character '*' runs).
		Safe to change:  YES. The targets are this game's map
		          layout — a path that does not resolve is a
		          WARNING and is skipped, so a typo is a silent
		          no-op at runtime.
		Read by:  EnvironmentModifier.ApplyColors
		Placeholder:  The TARGET PATHS are game-specific.
]]
Config.SNOWFALL_COLOR_GRAY = {
	Color = Color3.fromRGB(170, 170, 170),
	Targets = { 'Map.MainIsland.Paths', 'Base.Build.Paths' },
}

--[[
	EVENTS.Snowfall.Environment.Colors.White

		Default:  Color3.fromRGB(255, 255, 255)
		          Targets = { 'Map.MainIsland.Island.Grass',
		                      'Map.MainIsland.Decor.Grass',
		                      'Base.Build.Island.Grass',
		                      'Base.Build.Lamps.*.Bush' }
		Meaning:  Whitens the grass. The last target is a WILDCARD:
		          it finds the `Bush` under EVERY `Lamp`, in EVERY
		          base, however many exist. Multiple wildcards fan
		          out level by level; a plain name never fans out.
		Range:    as above.
		Safe to change:  YES.
		Read by:  EnvironmentModifier.ApplyColors,
		          EnvironmentModifier.ResolveRoots
		Placeholder:  The TARGET PATHS are game-specific.
]]
Config.SNOWFALL_COLOR_WHITE = {
	Color = Color3.fromRGB(255, 255, 255),
	Targets = {
		'Map.MainIsland.Island.Grass',
		'Map.MainIsland.Decor.Grass',
		'Base.Build.Island.Grass',
		'Base.Build.Lamps.*.Bush',
	},
}

-- =====================================================================
-- Path convention
-- =====================================================================

--[[
	PATH CONVENTION

		Default:  'Map....' | 'Base....' | '*'
		Meaning:  The shared convention for `Environment.Colors.*.Targets`
		          and `Lights.Containers`:
		            * 'Map....'  — resolved from Workspace, WITH the
		              Map segment as the first one.
		              "Map.MainIsland.Paths" means
		              Workspace.Map.MainIsland.Paths.
		            * 'Base....' — resolved inside EVERY player-base
		              folder (every child of Workspace.Map.Bases —
		              never only Base_1).
		              "Base.Build.Paths" means <each base>/Build/Paths.
		            * '*'        — wildcard: matches ALL children at
		              that exact path level, then continues resolving
		              the rest against every match.
		              "Base.Build.Lamps.*.Bush" finds Bush under EVERY
		              Lamp, however many exist.
		Range:    dot-separated non-empty segments; a lone '*' per
		          level; no leading/trailing dots; no '..'.
		Safe to change:  the convention itself, yes — but it is
		          hardcoded in `EnvironmentModifier.ResolveRoots`
		          (`if scope == 'Map' / elseif scope == 'Base'`).
		          THAT is the only place a path-specific branch
		          belongs. An unknown scope warns and is skipped.
		Read by:  EnvironmentModifier.ResolveRoots,
		          EnvironmentModifier.ApplyColors, EventLights.ApplyLights
		Placeholder:  The scope NAMES are this game's layout.
]]

-- =====================================================================
-- Luck pool order (a historical leftover — NOT used by this system)
-- =====================================================================

--[[
	LuckPoolOrder

		Default:  { 'Common', 'Uncommon', 'Rare', 'Epic', 'Legendary',
		            'Mythic' }
		Meaning:  The DESIGN pool order for luck tiers. It favours
		          Mythic most and is DELIBERATELY NOT
		          `Rarity.Order` (which sorts Mythic below
		          Legendary). It is read by
		          `ServerLuckService` (the SharedUtilities system) —
		          NOTHING in this system reads it.
		Range:    an array of rarity ids.
		Safe to change:  it changes the luck roll for every egg in
		          the game. It also changes the SharedUtilities
		          system's behaviour, so do not tune it while
		          thinking you are only touching Events.
		Read by:  ServerLuckService (SharedUtilities) — NOT by
		          EventService, EnvironmentModifier or EventLights
		Placeholder:  NO — but it is MISPLACED. It should live in
		              the SharedUtilities config, where the reader
		              lives.
]]
Config.LUCK_POOL_ORDER = {
	'Common',
	'Uncommon',
	'Rare',
	'Epic',
	'Legendary',
	'Mythic',
}

return table.freeze(Config)
