--!strict
--!native
--[[
	CANONICAL CONFIG (unified architecture).
	This module is the single source of truth for its domain; the legacy
	flat config under ReplicatedStorage.Config is a deprecated shim.
	New code must require this canonical path.
	Values below are preserved exactly from the pre-migration configs.
	Do NOT rebalance here without a gameplay review.
]]
--[[
	Events
	===========
	THE single authoritative source of truth for the Event
	system (EventService in ServerScriptService/Event reads
	this — nothing event-related is hardcoded in engine code).

	CONFIG DEFINES WHAT. ENGINE DEFINES HOW.

	Adding a future event (e.g. Volcano) is primarily config
	work: append one entry to `Events` (+ `Order` so the
	weighted scheduler can reach it). No engine change needed
	for duration / chance / assets / mutations / time / map
	colors / UI label — every one of those is data here.

	Architecture (how the engine consumes this):

	  Events
	      |
	      v
	  EventService (scheduler + lifecycle)
	      |
	  +---+---+-----------+
	  |       |           |
	  v       v           v
	  UI   Assets/    Mutations
	       Env/Time   (egg data)

	Events right now:
	  * Base     — the normal/default world state. NEVER
	    scheduled, NEVER started (it is the absence of a
	    special event). Exists so every system has a named
	    baseline to document + fall back to.
	  * Galaxy   — special event (night + Galactic mutation).
	  * Snowfall — special event (day + map recolor + Frost).

	Scheduling model (server authoritative): every
	`Scheduler.CycleSeconds`, ONE weighted roll over the
	enabled special events in `Order` plus an implicit "none"
	bucket of `Scheduler.NoneWeight`. With the current
	20/20/60 weights that is Galaxy 20%, Snowfall 20%,
	normal-cycle 60%. The winner is pre-decided so the UI can
	count down to it ("GALAXY EVENT IN 5:00").

	Path convention (Environment.Colors.*.Targets):
	  * "Map...."  — resolved from Workspace ("Map" is the
	    first segment): "Map.MainIsland.Paths" means
	    Workspace.Map.MainIsland.Paths.
	  * "Base...." — resolved inside EVERY player-base folder
	    (Workspace.Map.Bases.Base_1 .. Base_N — never only
	    Base_1): "Base.Build.Paths" means <each base>/Build/Paths.
	  * "*"        — wildcard: matches ALL children at that
	    exact path level, then continues resolving the rest
	    against every match. "Base.Build.Lamps.*.Bush" finds
	    Bush under EVERY Lamp, however many exist. Multiple
	    wildcards fan out level by level ("Map.*.*.Grass").
	    A plain name NEVER fans out (duplicate names resolve
	    to the single FindFirstChild hit).
	Every configured path is a RECURSIVE ROOT: the resolved
	instance itself is processed when it is a BasePart, plus
	every descendant BasePart at any depth. Adding a path to
	a Targets array automatically includes it — no engine
	change.

	Mutation cadence: events do NOT roll all eggs at start.
	A worker evaluates currently-eligible eggs every
	MutationIntervalSeconds while the event is active, so
	mutations happen progressively (including eggs that spawn
	or arrive after the event began). Chance stays per
	mutation (fraction 0..1); already-mutated eggs are always
	skipped, never overwritten.

	Overhead icons (Studio-authored, NOT code): the existing
	egg/animal overhead painters show a Mutations-container
	child named EXACTLY by mutation id when one exists
	(Galactic -> authored `Galactic` icon using
	Assets.Decals.GalaxyIcon; Frost -> authored `Frost` icon
	using Assets.Decals.SnowfallIcon), else a generic
	Mutation1-prototype clone. No ImageIds live in code.
]]

export type EventMutationEntry = {
	MutationId: string,
	Chance: number,
}

export type EventColorCategory = {
	Color: Color3,
	Targets: { string },
}

export type EventDefinition = {
	Id: string,
	Name: string,
	DisplayName: string,
	DurationSeconds: number,
	MutationIntervalSeconds: number,
	Scheduling: {
		Enabled: boolean,
		Weight: number,
	},
	Assets: {
		FolderName: string,
	},
	Mutations: { [string]: EventMutationEntry },
	Environment: {
		Colors: { [string]: EventColorCategory },
	},
	Lights: {
		Containers: { string },
	}?,
	Time: {
		Override: boolean,
		ClockTime: number,
	},
}

local Events = {}

-- --- Scheduler ----------------------------------------------------

-- Seconds between special-event opportunities. The winner of
-- each cycle's weighted roll is pre-decided at schedule time
-- so the UI countdown names the actual upcoming event.
Events.Scheduler = {
	CycleSeconds = 300,
	-- Implicit "no special event this cycle" weight. Current
	-- 20/20/60 split = Galaxy 20%, Snowfall 20%, normal 60%.
	NoneWeight = 60,
}

-- --- Start/stop transition cinematic -----------------------------------
--
-- ONE presentation layer around the authoritative lifecycle
-- (read by EventService for broadcast timing + by the client
-- transition controller for animation; server sends the same
-- numbers in the transition payload so late readers agree).
-- Timeline for a genuine Normal <-> Special change:
--   t=0.00  server broadcasts Prepare; clients start FOV zoom
--   t=0.05  white flash begins building (FOV leads, flash follows)
--   t=0.35  screen fully white
--   t=0.65  server performs the world change behind the white
--           (assets clone / cleanup, env + time apply/restore)
--   t=0.65  server broadcasts Reveal; clients fade white out
--           and ease FOV back over FadeOutSeconds
--   t=1.65  new world fully revealed
-- Short and polished by design: nobody stares at white.
Events.Transition = {
	-- Camera zoom while flashing: base FOV x multiplier
	-- (70 -> ~58). Relative — the live FOV is captured per
	-- player and restored exactly, never assumed.
	FovMultiplier = 0.83,
	-- FOV zoom duration (smooth easing). CURRENT: 0.35.
	FovSeconds = 0.35,
	-- Flash starts this far after the FOV zoom begins.
	-- CURRENT: 0.05.
	FlashDelaySeconds = 0.05,
	-- Transparent -> fully white. CURRENT: 0.3.
	FlashInSeconds = 0.3,
	-- Full-white dwell before the server acts (client-side
	-- hold; the server gate below is authoritative).
	-- CURRENT: 0.3.
	HoldSeconds = 0.3,
	-- Fully white -> transparent reveal. CURRENT: 1.
	FadeOutSeconds = 1,
	-- Server gate: Prepare broadcast -> world change. Must
	-- cover FlashDelay + FlashIn + Hold with margin.
	-- CURRENT: 0.65.
	CoverSeconds = 0.65,
}

-- --- Events ---------------------------------------------------------

-- Deterministic scheduler iteration order (pairs() order is
-- NOT guaranteed — the weighted roll walks this list).
Events.Order = { 'Galaxy', 'Snowfall' }

Events.Events = {
	Base = {
		Id = 'Base',
		Name = 'Normal',
		DisplayName = 'NORMAL',
		-- Base never "runs": duration 0, never scheduled,
		-- never started. It names the default world state
		-- the engine restores TO (by snapshotting actual
		-- originals, never by assuming defaults).
		DurationSeconds = 0,
		-- Base never runs, so no mutation worker cadence.
		MutationIntervalSeconds = 0,
		Scheduling = {
			Enabled = false,
			Weight = 0,
		},
		Assets = {
			FolderName = '',
		},
		Mutations = {},
		Environment = {
			Colors = {},
		},
		Time = {
			Override = false,
			ClockTime = 14,
		},
	},
	Galaxy = {
		Id = 'Galaxy',
		Name = 'Galaxy',
		DisplayName = 'GALAXY',
		DurationSeconds = 180,
		-- Progressive mutation cadence: eligible eggs are
		-- evaluated every 30s while Galaxy is active (6
		-- opportunities per run), never all at start.
		MutationIntervalSeconds = 30,
		Scheduling = {
			Enabled = true,
			Weight = 20,
		},
		-- Cloned from ServerStorage.Assets.Events.Galaxy
		-- into Workspace for the event's duration.
		Assets = {
			FolderName = 'Galaxy',
		},
		Mutations = {
			Galactic = {
				MutationId = 'Galactic',
				Chance = 0.8,
			},
		},
		-- Galaxy v1 needs no map recolor (night + assets
		-- carry it). Categories stay extensible: adding e.g.
		-- Colors.Purple.Targets here just works.
		Environment = {
			Colors = {},
		},
		-- Galaxy night lights: every Light under the island
		-- container plus every base's own container turns ON
		-- for the run, then restores its exact prior Enabled
		-- state. Containers resolve like Environment targets
		-- (Map.* live, Base.* per base); absent containers
		-- warn + skip, never abort.
		Lights = {
			Containers = {
				'Map.MainIsland.PointLights',
				'Base.PointLights',
			},
		},
		Time = {
			Override = true,
			ClockTime = 0,
		},
	},
	Snowfall = {
		Id = 'Snowfall',
		Name = 'Snowfall',
		DisplayName = 'SNOWFALL',
		DurationSeconds = 180,
		-- Same progressive cadence as Galaxy (per-event so a
		-- future event can tune its own rhythm).
		MutationIntervalSeconds = 30,
		Scheduling = {
			Enabled = true,
			Weight = 20,
		},
		-- Cloned from ServerStorage.Assets.Events.Snowfall
		-- into Workspace for the event's duration.
		Assets = {
			FolderName = 'Snowfall',
		},
		Mutations = {
			Frost = {
				MutationId = 'Frost',
				Chance = 0.8,
			},
		},
		Environment = {
			Colors = {
				Gray = {
					Color = Color3.fromRGB(170, 170, 170),
					Targets = {
						'Map.MainIsland.Paths',
						'Base.Build.Paths',
					},
				},
				White = {
					Color = Color3.fromRGB(255, 255, 255),
					Targets = {
						'Map.MainIsland.Island.Grass',
						'Map.MainIsland.Decor.Grass',
						'Base.Build.Island.Grass',
						-- Wildcard: Bush under EVERY Lamp, in
						-- EVERY base, however many exist.
						'Base.Build.Lamps.*.Bush',
					},
				},
			},
		},
		Time = {
			Override = true,
			ClockTime = 14,
		},
	},
} :: { [string]: EventDefinition }

-- --- Validation -----------------------------------------------------

function Events.Validate(): { string }
	local issues: { string } = {}
	local ok, err = pcall(function()
		local sched: any = Events.Scheduler
		if type(sched) ~= 'table' then
			issues[#issues + 1] = 'Scheduler must be a table'
		else
			if type(sched.CycleSeconds) ~= 'number' or sched.CycleSeconds < 10 then
				issues[#issues + 1] = 'Scheduler.CycleSeconds must be a number >= 10'
			end
			if type(sched.NoneWeight) ~= 'number' or sched.NoneWeight < 0 then
				issues[#issues + 1] = 'Scheduler.NoneWeight must be a number >= 0'
			end
		end
		if type(Events.Order) ~= 'table' or #Events.Order < 1 then
			issues[#issues + 1] = 'Order must be a non-empty array of event ids'
		end
		local transition: any = Events.Transition
		if type(transition) ~= 'table' then
			issues[#issues + 1] = 'Transition must be a table'
		else
			if
				type(transition.FovMultiplier) ~= 'number'
				or transition.FovMultiplier ~= transition.FovMultiplier
				or transition.FovMultiplier <= 0
				or transition.FovMultiplier >= 1
			then
				issues[#issues + 1] = 'Transition.FovMultiplier must narrow (0 < x < 1)'
			end
			if type(transition.FovSeconds) ~= 'number' or transition.FovSeconds < 0 then
				issues[#issues + 1] = 'Transition.FovSeconds must be a number >= 0'
			end
			if type(transition.FlashDelaySeconds) ~= 'number' or transition.FlashDelaySeconds < 0 then
				issues[#issues + 1] = 'Transition.FlashDelaySeconds must be a number >= 0'
			end
			if type(transition.FlashInSeconds) ~= 'number' or transition.FlashInSeconds <= 0 then
				issues[#issues + 1] = 'Transition.FlashInSeconds must be a number > 0'
			end
			if type(transition.HoldSeconds) ~= 'number' or transition.HoldSeconds < 0 then
				issues[#issues + 1] = 'Transition.HoldSeconds must be a number >= 0'
			end
			if type(transition.FadeOutSeconds) ~= 'number' or transition.FadeOutSeconds <= 0 then
				issues[#issues + 1] = 'Transition.FadeOutSeconds must be a number > 0'
			end
			if type(transition.CoverSeconds) ~= 'number' or transition.CoverSeconds < 0 then
				issues[#issues + 1] = 'Transition.CoverSeconds must be a number >= 0'
			else
				local coverFloor = transition.FlashDelaySeconds + transition.FlashInSeconds + transition.HoldSeconds
				if
					type(coverFloor) == 'number'
					and coverFloor == coverFloor
					and transition.CoverSeconds < coverFloor
				then
					issues[#issues + 1] = 'Transition.CoverSeconds must cover FlashDelay + FlashIn + Hold'
				end
			end
		end
		local events: any = Events.Events
		if type(events) ~= 'table' then
			issues[#issues + 1] = 'Events must be a table'
			return
		end
		if type(events.Base) ~= 'table' or events.Base.Id ~= 'Base' then
			issues[#issues + 1] = 'Events.Base must exist with Id == "Base"'
		end
		local seen: { [string]: boolean } = {}
		local order: any = Events.Order
		if type(order) == 'table' then
			for _, id in ipairs(order) do
				if type(id) ~= 'string' or id == '' then
					issues[#issues + 1] = 'Order entries must be non-empty strings'
				elseif seen[id] then
					issues[#issues + 1] = ('Order has duplicate id "%s"'):format(id)
				else
					seen[id] = true
					if id == 'Base' then
						issues[#issues + 1] = 'Order must not contain "Base" (Base is never scheduled)'
					elseif type(events[id]) ~= 'table' then
						issues[#issues + 1] = ('Order id "%s" has no Events entry'):format(id)
					end
				end
			end
		end
		for key, def in pairs(events) do
			local prefix = ('Events.%s'):format(tostring(key))
			if type(def) ~= 'table' then
				issues[#issues + 1] = prefix .. ' must be a table'
				continue
			end
			if def.Id ~= key then
				issues[#issues + 1] = prefix .. '.Id must equal its Events key'
			end
			if type(def.Name) ~= 'string' or def.Name == '' then
				issues[#issues + 1] = prefix .. '.Name must be a non-empty string'
			end
			if type(def.DisplayName) ~= 'string' or def.DisplayName == '' then
				issues[#issues + 1] = prefix .. '.DisplayName must be a non-empty string'
			end
			if type(def.DurationSeconds) ~= 'number' or def.DurationSeconds < 0 then
				issues[#issues + 1] = prefix .. '.DurationSeconds must be a number >= 0'
			end
			-- Progressive mutation cadence: startable events
			-- need a real interval (>= 5s so cycles never spin);
			-- Base never runs, so 0 is its only valid value.
			if type(def.MutationIntervalSeconds) ~= 'number' or def.MutationIntervalSeconds < 0 then
				issues[#issues + 1] = prefix .. '.MutationIntervalSeconds must be a number >= 0'
			elseif key == 'Base' and def.MutationIntervalSeconds ~= 0 then
				issues[#issues + 1] = prefix .. '.MutationIntervalSeconds must be 0 (Base never runs)'
			elseif key ~= 'Base' and def.MutationIntervalSeconds < 5 then
				issues[#issues + 1] = prefix .. '.MutationIntervalSeconds must be a number >= 5'
			end
			if type(def.Scheduling) ~= 'table' then
				issues[#issues + 1] = prefix .. '.Scheduling must be a table'
			else
				if type(def.Scheduling.Enabled) ~= 'boolean' then
					issues[#issues + 1] = prefix .. '.Scheduling.Enabled must be a boolean'
				end
				if type(def.Scheduling.Weight) ~= 'number' or def.Scheduling.Weight < 0 then
					issues[#issues + 1] = prefix .. '.Scheduling.Weight must be a number >= 0'
				end
			end
			if type(def.Assets) ~= 'table' or type(def.Assets.FolderName) ~= 'string' then
				issues[#issues + 1] = prefix .. '.Assets.FolderName must be a string'
			end
			if type(def.Mutations) ~= 'table' then
				issues[#issues + 1] = prefix .. '.Mutations must be a table'
			else
				for mKey, m in pairs(def.Mutations) do
					if type(m) ~= 'table' then
						issues[#issues + 1] = prefix .. '.Mutations.' .. tostring(mKey) .. ' must be a table'
					else
						if type(m.MutationId) ~= 'string' or m.MutationId == '' then
							issues[#issues + 1] = prefix
								.. '.Mutations.'
								.. tostring(mKey)
								.. '.MutationId must be a non-empty string'
						end
						if type(m.Chance) ~= 'number' or m.Chance < 0 or m.Chance > 1 then
							issues[#issues + 1] = prefix
								.. '.Mutations.'
								.. tostring(mKey)
								.. '.Chance must be a number in [0, 1]'
						end
					end
				end
			end
			if type(def.Environment) ~= 'table' or type(def.Environment.Colors) ~= 'table' then
				issues[#issues + 1] = prefix .. '.Environment.Colors must be a table'
			else
				for cKey, cat in pairs(def.Environment.Colors) do
					if type(cat) ~= 'table' then
						issues[#issues + 1] = prefix .. '.Environment.Colors.' .. tostring(cKey) .. ' must be a table'
					else
						if typeof(cat.Color) ~= 'Color3' then
							issues[#issues + 1] = prefix
								.. '.Environment.Colors.'
								.. tostring(cKey)
								.. '.Color must be a Color3'
						end
						if type(cat.Targets) ~= 'table' then
							issues[#issues + 1] = prefix
								.. '.Environment.Colors.'
								.. tostring(cKey)
								.. '.Targets must be an array of path strings'
						else
							for _, target in ipairs(cat.Targets) do
								-- Non-empty strings with no empty segments:
								-- 'Map..Paths', leading/trailing dots, and
								-- multi-char runs like '**' are malformed
								-- (a lone '*' per level is the wildcard).
								local malformed = type(target) ~= 'string' or target == ''
								if not malformed then
									if
										string.sub(target, 1, 1) == '.'
										or string.sub(target, -1) == '.'
										or string.find(target, '%.%.', 1, true) ~= nil
									then
										malformed = true
									else
										for seg in string.gmatch(target, '[^.]+') do
											if seg == '' or (#seg > 1 and string.find(seg, '*', 1, true) ~= nil) then
												malformed = true
												break
											end
										end
									end
								end
								if malformed then
									issues[#issues + 1] = prefix
										.. '.Environment.Colors.'
										.. tostring(cKey)
										.. '.Targets entries must be dot-separated names with lone-* wildcards'
									break
								end
							end
						end
					end
				end
				-- Event night lights: optional per event (Galaxy only
				-- today). When present, Containers must list
				-- non-empty container paths; resolution itself
				-- warns + skips at runtime, never here.
				if def.Lights ~= nil then
					if type(def.Lights) ~= 'table' or type(def.Lights.Containers) ~= 'table' then
						issues[#issues + 1] = prefix .. '.Lights must be a table with a Containers array'
					else
						for _, target in ipairs(def.Lights.Containers) do
							if type(target) ~= 'string' or target == '' then
								issues[#issues + 1] = prefix .. '.Lights.Containers entries must be non-empty strings'
								break
							end
						end
					end
				end
			end
			if type(def.Time) ~= 'table' then
				issues[#issues + 1] = prefix .. '.Time must be a table'
			else
				if type(def.Time.Override) ~= 'boolean' then
					issues[#issues + 1] = prefix .. '.Time.Override must be a boolean'
				end
				if type(def.Time.ClockTime) ~= 'number' or def.Time.ClockTime < 0 or def.Time.ClockTime > 24 then
					issues[#issues + 1] = prefix .. '.Time.ClockTime must be a number in [0, 24]'
				end
			end
		end
	end)
	if not ok then
		issues[#issues + 1] = 'Events validation crashed: ' .. tostring(err)
	end
	return issues
end

-- --- Luck pool order (moved from ServerLuckService.LUCK_POOL) ---
-- DESIGN pool for luck tiers: favors Mythic most. Deliberately NOT
-- Rarity.Order (which sorts Mythic below Legendary). One source of truth;
-- ServerLuckService reads this instead of maintaining its own order.
Events.LuckPoolOrder = {
	'Common',
	'Uncommon',
	'Rare',
	'Epic',
	'Legendary',
	'Mythic',
}
return table.freeze(Events)
