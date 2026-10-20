--!strict
--!native
--[[
	Event.EventService
	==================
	THE one generic event engine. It knows HOW events run;
	EventConfig (ReplicatedStorage/Config/EventConfig.lua)
	defines WHAT each event is. Galaxy/Snowfall are data, not
	scripts — there is intentionally no GalaxyEventScript or
	SnowfallEventScript anywhere.

	Pipeline (config -> engine -> world):

	  EventConfig -> EventService -> Scheduler / World / Eggs
	                                     |         |       |
	                                     v         v       v
	                                     UI    Assets/  egg.Mutations
	                                           Env/Time (persistent data)

	Lifecycle:
	  SERVER START -> Init -> Start -> ScheduleNext (pre-pick
	  next special event + publish UI timestamps) -> countdown
	  -> StartEvent (assets clone, time override, env colors,
	  mutation worker armed, UI) -> duration (progressive
	  mutation cycles) -> EndEvent (remove assets, restore
	  env/time, keep egg mutations, UI) -> ScheduleNext -> repeat.

	Rules enforced here:
	  * One special event at a time (a start while active ends
	    the previous one through the SAME cleanup path first).
	  * Scheduler + admin call the SAME StartEvent/EndEvent.
	  * Egg mutations are persistent gameplay data: event end
	    NEVER strips them. Hatch inheritance is automatic via
	    the existing TraitService.ResolveInheritance path (the
	    egg already carries the mutation id).
	  * Already-mutated eggs are protected from overwrite.
	  * Every world change (assets/time/colors) has a cleanup
	    path; cleanup is idempotent.
  * Server authoritative: scheduler, RNG, state, assets,
    mutations, time. Clients render countdowns from
    replicated timestamps, plus the start/stop transition
    cinematic (FOV + white flash + fade) from the
    server-wide EventTransition broadcast — presentation
    only, never state.
]]

local RunService = game:GetService('RunService')
local Workspace = game:GetService('Workspace')
local Lighting = game:GetService('Lighting')
local ReplicatedStorage = game:GetService('ReplicatedStorage')
local ServerStorage = game:GetService('ServerStorage')

local EventConfig = require(ReplicatedStorage.Config.World.Events)
local RarityConfig = require(ReplicatedStorage.Config.Creatures.Rarity)
local Debug = require(ReplicatedStorage.Utility.Debug)
local Remotes = require(ReplicatedStorage.Utility.Remotes)
local Players = game:GetService('Players')
-- Funnel analytics (leaf module — never gameplay-critical).
local FunnelService = require(script.Parent.Parent.FunnelService)

local EnvironmentModifier = require(script.Parent.EnvironmentModifier)
local EventLights = require(script.Parent.EventLights)

local EventService = {}

-- --- Lazy service refs (no load-time cycles) ------------------------

local _spawnService: any = nil
local _playerService: any = nil
local _mutationService: any = nil
local _eggOverhead: any = nil
local _notificationService: any = nil
-- TEST seam: override owner-player resolution (headless specs
-- have no Players; production passes nil = live service).
-- Cleared by _TestReset. Never used for anything but the
-- base-egg owner toast.
local _testPlayerResolver: ((number) -> any)? = nil

function EventService._TestSetPlayerResolver(fn: ((number) -> any)?)
	_testPlayerResolver = fn
end

local function _resolveOwnerPlayer(ownerUserId: number): Player?
	if _testPlayerResolver ~= nil then
		local override: Player? = nil
		pcall(function()
			override = (_testPlayerResolver :: (number) -> any)(ownerUserId)
		end)
		return override
	end
	local player: Player? = nil
	pcall(function()
		player = game:GetService('Players'):GetPlayerByUserId(ownerUserId)
	end)
	return player
end

local function _services(): boolean
	if _spawnService ~= nil and _playerService ~= nil and _mutationService ~= nil then
		return true
	end
	local ok = pcall(function()
		local sss = game:GetService('ServerScriptService')
		if _spawnService == nil then
			_spawnService = require(sss.Egg.SpawnService)
		end
		if _playerService == nil then
			_playerService = require(sss.PlayerService)
		end
		if _mutationService == nil then
			_mutationService = require(sss.MutationService)
		end
		if _eggOverhead == nil then
			_eggOverhead = require(sss.Egg.EggOverhead)
		end
	end)
	return ok and _spawnService ~= nil and _playerService ~= nil and _mutationService ~= nil
end

-- --- State -------------------------------------------------------------

export type ActiveEvent = {
	Id: string,
	RunId: number,
	StartedAt: number,
	EndAt: number,
	Source: string,
}

export type NextEvent = {
	Id: string?,
	At: number,
}

local _current: ActiveEvent? = nil
local _next: NextEvent? = nil
local _runId = 0
local _revision = 0
local _tickConn: RBXScriptConnection? = nil
local _accum = 0
local _mutAccum = 0
local _started = false

-- World-change handles (temporary state — restored on end).
local _assetClone: Instance? = nil
local _envSnapshot: any = nil
local _savedClockTime: number? = nil
local _lightsSnapshot: any = nil
-- Headless-test seam: override the live light roots
-- (production passes nil = live Workspace). Cleared by
-- _TestReset.
local _testLightsRoots: any = nil

function EventService._TestSetLightsRoots(mapRoot: Instance?, baseRoots: { Instance }?)
	if mapRoot == nil and baseRoots == nil then
		_testLightsRoots = nil
	else
		_testLightsRoots = { mapRoot = mapRoot, baseRoots = baseRoots }
	end
end

-- Start/stop transition cinematic (presentation ONLY — the
-- lifecycle below stays authoritative). ONE broadcast remote
-- (EventTransition) reaches every client in the server:
--   Prepare(Kind, EventId, TransitionId, timings): FOV zoom +
--     white flash begin now; the world change lands after
--     CoverSeconds, behind full white.
--   Reveal(Kind, EventId, TransitionId): the world change is
--     committed; fade out and restore FOV.
-- The server NEVER waits on clients: it gates on the fixed
-- CoverSeconds, then acts. Joins/leaves/lag can't deadlock it
-- (final truth stays in the replicated attributes); a replace
-- (Galaxy -> Snowfall) runs as ONE continuous transition, not
-- two flashes. _transitionSeq mints TransitionIds; the client
-- ignores unknown/replayed ids.
local _transitionSeq = 0
local _transitionId: number? = nil
local _suppressTransition = false
-- TEST seam: override the cover gate (specs only — production
-- always waits the configured CoverSeconds so clients reach
-- full white first). Cleared by _TestReset.
local _testCoverOverride: number? = nil
-- TEST seam: every broadcast payload, in order (specs assert
-- Prepare/Reveal sequencing without clients). Capped so the
-- live server never accumulates history.
local _testBroadcasts: { any } = {}
local _TEST_BROADCAST_CAP = 50

function EventService._TestSetTransitionCover(seconds: number?)
	_testCoverOverride = seconds
end

function EventService._TestBroadcasts(): { any }
	local out: { any } = {}
	for _, payload in ipairs(_testBroadcasts) do
		out[#out + 1] = payload
	end
	return out
end

function EventService._TestIsTransitioning(): boolean
	return _transitionId ~= nil
end

-- Resolved transition timings (config-first, defensive
-- fallbacks identical to the client defaults). Never throws.
local function _transitionTimings(): any
	local fallback = {
		FovMultiplier = 0.83,
		FovSeconds = 0.35,
		FlashDelaySeconds = 0.05,
		FlashInSeconds = 0.3,
		FadeOutSeconds = 1,
		CoverSeconds = 0.65,
	}
	pcall(function()
		local cfg: any = EventConfig.Transition
		if type(cfg) ~= 'table' then
			return
		end
		if type(cfg.FovMultiplier) == 'number' and cfg.FovMultiplier > 0 and cfg.FovMultiplier < 1 then
			fallback.FovMultiplier = cfg.FovMultiplier
		end
		if type(cfg.FovSeconds) == 'number' and cfg.FovSeconds >= 0 then
			fallback.FovSeconds = cfg.FovSeconds
		end
		if type(cfg.FlashDelaySeconds) == 'number' and cfg.FlashDelaySeconds >= 0 then
			fallback.FlashDelaySeconds = cfg.FlashDelaySeconds
		end
		if type(cfg.FlashInSeconds) == 'number' and cfg.FlashInSeconds > 0 then
			fallback.FlashInSeconds = cfg.FlashInSeconds
		end
		if type(cfg.FadeOutSeconds) == 'number' and cfg.FadeOutSeconds > 0 then
			fallback.FadeOutSeconds = cfg.FadeOutSeconds
		end
		if type(cfg.CoverSeconds) == 'number' and cfg.CoverSeconds >= 0 then
			fallback.CoverSeconds = cfg.CoverSeconds
		end
	end)
	if type(_testCoverOverride) == 'number' and (_testCoverOverride :: number) >= 0 then
		fallback.CoverSeconds = _testCoverOverride :: number
	end
	return fallback
end

local function _broadcastTransition(phase: string, kind: string, eventId: string, token: number, timings: any)
	local payload: any = nil
	pcall(function()
		if phase == 'Prepare' then
			payload = {
				Phase = 'Prepare',
				Kind = kind,
				EventId = eventId,
				TransitionId = token,
				FovMultiplier = timings.FovMultiplier,
				FovSeconds = timings.FovSeconds,
				FlashDelaySeconds = timings.FlashDelaySeconds,
				FlashInSeconds = timings.FlashInSeconds,
				FadeOutSeconds = timings.FadeOutSeconds,
				CoverSeconds = timings.CoverSeconds,
			}
		else
			payload = {
				Phase = 'Reveal',
				Kind = kind,
				EventId = eventId,
				TransitionId = token,
			}
		end
	end)
	if type(payload) ~= 'table' then
		return
	end
	_testBroadcasts[#_testBroadcasts + 1] = payload
	if #_testBroadcasts > _TEST_BROADCAST_CAP then
		table.remove(_testBroadcasts, 1)
	end
	pcall(function()
		Remotes.FireAllClients(Remotes.Names.EventTransition, payload)
	end)
end

-- --- Time + replication -------------------------------------------------

local function _serverNow(): number
	local t: number? = nil
	pcall(function()
		t = Workspace:GetServerTimeNow()
	end)
	if type(t) == 'number' then
		return t
	end
	return os.time()
end

local function _publish()
	pcall(function()
		local currentId = ''
		local endAt = 0
		if _current ~= nil then
			currentId = (_current :: ActiveEvent).Id
			endAt = (_current :: ActiveEvent).EndAt
		end
		local nextId = ''
		local nextAt = 0
		if _next ~= nil then
			nextId = (_next :: NextEvent).Id or ''
			nextAt = (_next :: NextEvent).At
		end
		_revision += 1
		ReplicatedStorage:SetAttribute('Event_CurrentId', currentId)
		ReplicatedStorage:SetAttribute('Event_EndAt', endAt)
		ReplicatedStorage:SetAttribute('Event_NextId', nextId)
		ReplicatedStorage:SetAttribute('Event_NextAt', nextAt)
		ReplicatedStorage:SetAttribute('Event_Revision', _revision)
	end)
end

-- --- Config reads --------------------------------------------------------

-- Canonical definition or nil (unknown id is data, never a crash).
function EventService.GetEvent(eventId: any): any
	if type(eventId) ~= 'string' then
		return nil
	end
	local events: any = EventConfig.Events
	if type(events) ~= 'table' then
		return nil
	end
	local def = events[eventId]
	if type(def) ~= 'table' then
		return nil
	end
	return def
end

-- Is this event startable right now (exists, not Base)?
function EventService.IsStartable(eventId: any): boolean
	local def = EventService.GetEvent(eventId)
	if def == nil then
		return false
	end
	return eventId ~= 'Base'
end

-- Weighted pick of the next special event over EventConfig.Order
-- (+ implicit NoneWeight bucket). Returns the event id or nil
-- for a normal cycle. `rollOverride` in [0, 1) is the test seam
-- (production passes nil = math.random()).
function EventService.PickNextEventId(rollOverride: number?): string?
	local picked: string? = nil
	pcall(function()
		local order: any = EventConfig.Order
		local events: any = EventConfig.Events
		local sched: any = EventConfig.Scheduler
		if type(order) ~= 'table' or type(events) ~= 'table' then
			return
		end
		type WeightedEntry = { Id: string, Weight: number }
		local entries: { WeightedEntry } = {}
		local total = 0
		for _, id in ipairs(order) do
			if type(id) == 'string' and id ~= '' and id ~= 'Base' then
				local def: any = events[id]
				if type(def) == 'table' and type(def.Scheduling) == 'table' then
					if
						def.Scheduling.Enabled == true
						and type(def.Scheduling.Weight) == 'number'
						and def.Scheduling.Weight > 0
					then
						entries[#entries + 1] = { Id = id, Weight = def.Scheduling.Weight }
						total += def.Scheduling.Weight
					end
				end
			end
		end
		local noneWeight = 0
		if type(sched) == 'table' and type(sched.NoneWeight) == 'number' and sched.NoneWeight > 0 then
			noneWeight = sched.NoneWeight
		end
		total += noneWeight
		if total <= 0 then
			return
		end
		local roll: number
		if type(rollOverride) == 'number' then
			roll = math.clamp(rollOverride :: number, 0, 0.999999) * total
		else
			roll = math.random() * total
		end
		local acc = 0
		for _, entry in ipairs(entries) do
			acc += entry.Weight
			if roll < acc then
				picked = entry.Id
				return
			end
		end
		picked = nil
	end)
	return picked
end

-- Pure mutation-chance gate (server-side RNG lives in
-- TryMutateEgg; `rollOverride` is the test seam).
function EventService.RollMutationChance(chance: any, rollOverride: number?): boolean
	if type(chance) ~= 'number' or chance <= 0 then
		return false
	end
	if chance >= 1 then
		return true
	end
	local roll: number
	if type(rollOverride) == 'number' then
		roll = rollOverride :: number
	else
		roll = math.random()
	end
	return roll < chance
end

-- Client countdown text helper (M:SS, matches "5:00" style).
function EventService.FormatCountdown(totalSeconds: number): string
	local s = math.max(0, math.floor(totalSeconds or 0))
	local mins = math.floor(s / 60)
	local secs = s % 60
	return string.format('%d:%02d', mins, secs)
end

-- --- Scheduler -----------------------------------------------------------

function EventService.GetCurrentEvent(): ActiveEvent?
	return _current
end

function EventService.GetNextEvent(): NextEvent?
	return _next
end

-- Pre-decide the next cycle's special event (or nil for a
-- normal cycle) and publish UI timestamps. Never throws.
function EventService.ScheduleNext(reason: string?)
	pcall(function()
		local cycle = 300
		pcall(function()
			local sched: any = EventConfig.Scheduler
			if type(sched) == 'table' and type(sched.CycleSeconds) == 'number' and sched.CycleSeconds >= 10 then
				cycle = sched.CycleSeconds
			end
		end)
		local id = EventService.PickNextEventId()
		_next = { Id = id, At = _serverNow() + cycle }
		_publish()
		Debug.Log('EV', 'next event scheduled', {
			next = tostring(id),
			inSeconds = tostring(cycle),
			reason = tostring(reason),
		})
	end)
end

-- --- World application / restoration --------------------------------------

local function _applyAssets(def: any): boolean
	pcall(function()
		local folderName: string? = nil
		pcall(function()
			folderName = def.Assets.FolderName
		end)
		if type(folderName) ~= 'string' or folderName == '' then
			return
		end
		local source: Instance? = nil
		pcall(function()
			local assets = ServerStorage:FindFirstChild('Assets')
			local events = assets and assets:FindFirstChild('Events') or nil
			source = events and events:FindFirstChild(folderName :: string) or nil
		end)
		if source == nil then
			Debug.Warn('EV', 'event asset folder missing; continuing without assets', {
				event = tostring(def.Id),
				expected = 'ServerStorage.Assets.Events.' .. tostring(folderName),
			})
			return
		end
		local clone: Instance? = nil
		pcall(function()
			clone = (source :: Instance):Clone()
		end)
		if clone == nil then
			return
		end
		(clone :: Instance).Name = 'EventAssets_' .. tostring(def.Id);
		(clone :: Instance).Parent = Workspace
		_assetClone = clone
		Debug.Log('EV', 'cloned event assets', { event = tostring(def.Id) })
	end)
	return _assetClone ~= nil
end

local function _removeAssets()
	pcall(function()
		if _assetClone ~= nil then
			local clone = _assetClone
			_assetClone = nil
			pcall(function()
				(clone :: Instance):Destroy()
			end)
		end
	end)
end

local function _applyTime(def: any)
	pcall(function()
		local override = false
		local clock = 14
		pcall(function()
			override = def.Time.Override == true
			if type(def.Time.ClockTime) == 'number' then
				clock = def.Time.ClockTime
			end
		end)
		if not override then
			return
		end
		pcall(function()
			_savedClockTime = Lighting.ClockTime
			Lighting.ClockTime = clock
		end)
		Debug.Log('EV', 'applied time override', { event = tostring(def.Id), clockTime = tostring(clock) })
	end)
end

local function _restoreTime()
	pcall(function()
		if _savedClockTime ~= nil then
			local saved = _savedClockTime
			_savedClockTime = nil
			pcall(function()
				Lighting.ClockTime = saved :: number
			end)
		end
	end)
end

local function _applyEnvironment(def: any): number
	local count = 0
	pcall(function()
		local colors: any = nil
		pcall(function()
			colors = def.Environment.Colors
		end)
		_envSnapshot = EnvironmentModifier.ApplyColors(colors)
		pcall(function()
			count = #(_envSnapshot :: any).entries
		end)
		Debug.Log('EV', 'applied environment transformation', {
			event = tostring(def.Id),
			parts = tostring(count),
		})
	end)
	return count
end

local function _restoreEnvironment()
	pcall(function()
		EnvironmentModifier.Restore(_envSnapshot)
		_envSnapshot = nil
		Debug.Log('EV', 'restored environment', {})
	end)
end

-- Event night lights (Galaxy only today): every Light under
-- the configured containers turns ON for the run. Runs
-- inside the transition's white window (after the cover
-- gate), like assets/env/time. Missing containers warn +
-- skip; a lightless place is a silent no-op.
local function _applyLights(def: any)
	pcall(function()
		local cfg: any = nil
		pcall(function()
			cfg = def.Lights
		end)
		_lightsSnapshot = EventLights.ApplyLights(cfg, _testLightsRoots)
		local count = 0
		pcall(function()
			count = #(_lightsSnapshot :: any).entries
		end)
		Debug.Log('EV', 'applied event lights', {
			event = tostring(def.Id),
			lights = tostring(count),
		})
	end)
end

local function _restoreLights()
	pcall(function()
		EventLights.Restore(_lightsSnapshot)
		_lightsSnapshot = nil
		Debug.Log('EV', 'restored event lights', {})
	end)
end

-- --- Mutations ---------------------------------------------------------------

-- Owner notify for base eggs: the canonical
-- NotificationService success path (toast + Approved SFX
-- for THAT player only, via the Event_EggMutated catalog
-- entry). Fires ONLY here — inside a real new assignment
-- to a Placed egg with a live owner. Spawn-with-mutation,
-- Traveling eggs, offline owners, hatch inheritance, and
-- protected re-rolls never notify. Never throws.
local function _notifyBaseEggOwner(egg: any, mutationId: string)
	pcall(function()
		if type(egg) ~= 'table' or egg.state ~= 'Placed' then
			return
		end
		local owner = egg.ownerUserId
		if type(owner) ~= 'number' then
			return
		end
		if _notificationService == nil then
			local ok, svc = pcall(function()
				return require(game:GetService('ServerScriptService').Base.NotificationService)
			end)
			if not ok or svc == nil then
				return
			end
			_notificationService = svc
		end
		local player: Player? = nil
		pcall(function()
			player = _resolveOwnerPlayer(owner)
		end)
		if player == nil then
			return
		end
		local displayName = 'Egg'
		pcall(function()
			local named: any = RarityConfig.RarityDisplayName[egg.rarity]
			if type(named) == 'string' and named ~= '' then
				displayName = named
			end
		end)
		_notificationService.NotifySuccess(player, 'Event_EggMutated', {
			EggName = displayName,
			Rarity = egg.rarity,
			MutationName = mutationId,
		})
		Debug.Log('EV', 'base-egg mutation notified', {
			egg = tostring(egg.uniqueId),
			owner = tostring(owner),
			mutation = tostring(mutationId),
		})
	end)
end

-- One-time server-side mutation roll for a single egg against
-- the CURRENT event. Evaluated fresh on every call (the worker
-- calls this once per egg per cycle; retries across cycles are
-- intended): unmutated eligible eggs roll, already-mutated eggs
-- are protected from overwrite, and non-eligible states are
-- skipped. `rollOverride` is the test seam. Returns true on a
-- new mutation, false otherwise. Never throws.
function EventService.TryMutateEgg(egg: any, rollOverride: number?): boolean
	local mutated = false
	pcall(function()
		if _current == nil then
			return
		end
		local current = _current :: ActiveEvent
		if type(egg) ~= 'table' then
			return
		end
		-- NOTE: deliberately NO per-event run stamp. Every
		-- worker cycle re-evaluates unmutated eggs (failures
		-- retry later in the event); the existing-mutation
		-- guard below is the only skip, so protection can
		-- never be bypassed and retries can never duplicate.
		local def = EventService.GetEvent(current.Id)
		if def == nil or type(def.Mutations) ~= 'table' then
			return
		end
		-- Eligibility: unhatched eggs only. Consumed/Opening
		-- (and anything already gone) never roll.
		local state: any = egg.state
		if state ~= 'Available' and state ~= 'Traveling' and state ~= 'Placed' then
			return
		end
		-- Conflict rule: an already-mutated egg keeps its
		-- mutation — never overwritten by an event roll.
		local existing: { string } = {}
		pcall(function()
			if _mutationService ~= nil then
				existing = _mutationService.SanitizeList(egg.Mutations)
			elseif type(egg.Mutations) == 'table' then
				for _, id in ipairs(egg.Mutations) do
					if type(id) == 'string' and id ~= '' then
						existing[#existing + 1] = id
					end
				end
			end
		end)
		if #existing > 0 then
			return
		end
		for _, entry in pairs(def.Mutations) do
			if type(entry) == 'table' and type(entry.MutationId) == 'string' and entry.MutationId ~= '' then
				if EventService.RollMutationChance(entry.Chance, rollOverride) then
					local valid = true
					pcall(function()
						if _mutationService ~= nil then
							valid = _mutationService.IsValidMutation(entry.MutationId)
						end
					end)
					if valid then
						egg.Mutations = { entry.MutationId }
						-- Persist onto the profile row when this
						-- egg is owned (base eggs), so rejoin +
						-- hatch see the same mutation.
						pcall(function()
							local owner = egg.ownerUserId
							local uid = egg.uniqueId
							if type(owner) == 'number' and type(uid) == 'string' and uid ~= '' then
								_playerService.SetEggMutations(owner, uid, egg.Mutations)
							end
						end)
						-- Repaint the overhead so the new icon
						-- shows immediately (Studio-authored
						-- per-id icon child when present, else
						-- the canonical mutation decal stamped
						-- by MutationIcon).
						pcall(function()
							if _eggOverhead ~= nil and egg.model ~= nil then
								_eggOverhead.Refresh(egg)
							end
						end)
						-- Base-egg owner feedback (toast + Approved
						-- SFX for the owner only — inside the real
						-- assignment, so no change means no notify).
						_notifyBaseEggOwner(egg, entry.MutationId)
						mutated = true
						-- Funnel: mutation committed above (assignment
						-- + persistence + owner notify). Only owned
						-- eggs attribute to a player; center eggs
						-- are world outcomes, logged honestly as
						-- unattributed skips.
						pcall(function()
							local owner = egg.ownerUserId
							if type(owner) ~= 'number' then
								return
							end
							local ownerPlayer: Player? = nil
							pcall(function()
								ownerPlayer = Players:GetPlayerByUserId(owner)
							end)
							if ownerPlayer == nil then
								return
							end
							local eventId = tostring(current.Id)
							FunnelService:LogStep(ownerPlayer, 'Event', 'EventParticipated', {
								event_id = eventId,
								_key = eventId,
							})
							FunnelService:LogStep(ownerPlayer, 'Event', 'MutationReceived', {
								mutation = tostring(entry.MutationId),
								event_id = eventId,
							})
						end)
						-- Team-Test trace: full egg→slot context so a
						-- run proves WHICH egg was mutated, in which
						-- slot context (CENTER = global spawn egg
						-- with slotId nil; otherwise the owning
						-- slot id), and that base eggs notify only
						-- their own owner. Mutations are rare; one
						-- print per assignment is not spam.
						local eggPath = '?'
						pcall(function()
							if typeof(egg.model) == 'Instance' then
								eggPath = (egg.model :: Instance):GetFullName()
							end
						end)
						local slotCtx = '?'
						pcall(function()
							slotCtx = if type(egg.slotId) == 'string' and egg.slotId ~= '' then egg.slotId else 'CENTER'
						end)
						Debug.Log('EventMutation', ('event=%s eggId=%s egg=%s slot=%s state=%s owner=%s mutationBefore=none mutationAfter=%s'):format(
								tostring(current.Id),
								tostring(egg.uniqueId),
								eggPath,
								slotCtx,
								tostring(egg.state),
								tostring(egg.ownerUserId),
								tostring(entry.MutationId)
							))
						Debug.Log('EV', 'mutation roll: egg mutated', {
							egg = tostring(egg.uniqueId),
							mutation = tostring(entry.MutationId),
							event = tostring(current.Id),
						})
					end
					break
				end
			end
		end
	end)
	return mutated
end

-- One progressive mutation cycle: evaluate every
-- currently-eligible live egg ONCE against the active event
-- (Available + Traveling + Placed via the single SpawnService
-- registry — including eggs that spawned or arrived after the
-- event began). Unmutated eggs roll fresh every cycle, so
-- mutations happen over time rather than all at start;
-- already-mutated eggs are always skipped, never retried.
-- `rollOverride` is the test seam (production passes nil).
-- Returns the number of new mutations. Never throws. No-op
-- (0) when no event is active.
function EventService.RunMutationCycle(rollOverride: number?): number
	local count = 0
	pcall(function()
		if _current == nil then
			return
		end
		if not _services() then
			Debug.Warn('EV', 'mutation cycle skipped: services unavailable', {})
			return
		end
		local list: { any } = {}
		pcall(function()
			list = _spawnService.AllEggs()
		end)
		for _, egg in ipairs(list) do
			if EventService.TryMutateEgg(egg, rollOverride) then
				count += 1
			end
		end
		Debug.Log('EV', 'mutation cycle complete', {
			event = tostring((_current :: ActiveEvent).Id),
			mutated = tostring(count),
		})
	end)
	return count
end

-- --- Lifecycle ---------------------------------------------------------------

-- Start `eventId` through the full lifecycle (assets, time,
-- environment, UI — then the progressive mutation worker arms
-- and evaluates eligible eggs on its configured interval,
-- NEVER all at start). Scheduler + admin call this SAME
-- function. If another event is active it is ended through the
-- normal cleanup path first (one-at-a-time rule).
-- Cinematic: a genuine Normal -> Special start broadcasts ONE
-- Prepare, gates CoverSeconds so every client reaches full
-- white, performs the world change behind the white, then
-- broadcasts Reveal. A replace (Galaxy -> Snowfall) rides the
-- SAME single transition (the inner end is suppressed, never
-- a second flash). Returns (true) or (false, reason). Never
-- throws (and never traps clients behind white on error).
function EventService.StartEvent(eventId: any, source: any): (boolean, string?)
	local ok = false
	local reason: string? = nil
	local startedToken: number? = nil
	pcall(function()
		local src = if type(source) == 'string' and source ~= '' then source else 'unknown'
		if not EventService.IsStartable(eventId) then
			reason = ('Unknown or non-startable event: "%s"'):format(tostring(eventId))
			return
		end
		if not _services() then
			reason = 'Event services unavailable'
			return
		end
		local def = EventService.GetEvent(eventId)
		if _current ~= nil and (_current :: ActiveEvent).Id == eventId then
			reason = ('Event "%s" is already active'):format(tostring(eventId))
			return
		end
		if _transitionId ~= nil then
			reason = 'An event transition is already in progress'
			return
		end
		local replacing = _current ~= nil
		-- Consume the schedule BEFORE the cover gate: the tick
		-- keeps running during the wait, and a still-set _next
		-- would re-enter StartEvent (rejected) and burn a retry
		-- roll. _current lands below, after the gate.
		_next = nil
		_transitionSeq += 1
		_transitionId = _transitionSeq
		startedToken = _transitionId
		local token = _transitionId :: number
		local timings = _transitionTimings()
		_broadcastTransition('Prepare', 'Start', eventId, token, timings)
		task.wait(timings.CoverSeconds)
		if replacing then
			_suppressTransition = true
			local replaceOk = EventService.EndEvent('replace')
			_suppressTransition = false
			if not replaceOk then
				_broadcastTransition('Reveal', 'Start', eventId, token, timings)
				_transitionId = nil
				startedToken = nil
				reason = 'Previous event failed to end'
				return
			end
		end
		local duration = 180
		pcall(function()
			if type(def.DurationSeconds) == 'number' and def.DurationSeconds > 0 then
				duration = def.DurationSeconds
			end
		end)
		local now = _serverNow()
		_runId += 1
		_current = {
			Id = eventId,
			RunId = _runId,
			StartedAt = now,
			EndAt = now + duration,
			Source = src,
		}
		_mutAccum = 0
		Debug.Log('EV', 'starting event', { event = tostring(eventId), source = src })
		_applyTime(def)
		_applyAssets(def)
		_applyEnvironment(def)
		_applyLights(def)
		_publish()
		Debug.Log('EV', 'event active (mutation worker armed)', { event = tostring(eventId) })
		_broadcastTransition('Reveal', 'Start', eventId, token, timings)
		_transitionId = nil
		startedToken = nil
		ok = true
	end)
	if startedToken ~= nil then
		-- The body threw mid-transition (every apply path is
		-- internally guarded, so this is unreachable in
		-- practice): reveal anyway — never trap clients white.
		_broadcastTransition('Reveal', 'Start', tostring(eventId), startedToken, _transitionTimings())
		_transitionId = nil
	end
	return ok, reason
end

-- End the active event through the normal cleanup path
-- (assets removed, environment + time restored, egg mutations
-- KEPT — they are persistent gameplay data). Idempotent:
-- ending with nothing active is a safe no-op returning true.
-- Cinematic: a genuine Special -> Normal end broadcasts ONE
-- Prepare, gates CoverSeconds, cleans up behind full white,
-- then broadcasts Reveal. A concurrent transition rejects
-- with false (the tick retries next second); a suppressed
-- replace-end (from StartEvent) runs silently inside the
-- start's single transition. Never throws (and never traps
-- clients behind white on error).
function EventService.EndEvent(source: any): boolean
	local done = true
	local startedToken: number? = nil
	pcall(function()
		local src = if type(source) == 'string' and source ~= '' then source else 'unknown'
		if _current == nil then
			return
		end
		if _transitionId ~= nil and not _suppressTransition then
			done = false
			return
		end
		local id = (_current :: ActiveEvent).Id
		local token = 0
		local timings: any = nil
		if not _suppressTransition then
			_transitionSeq += 1
			_transitionId = _transitionSeq
			startedToken = _transitionId
			token = _transitionId :: number
			timings = _transitionTimings()
			_broadcastTransition('Prepare', 'End', id, token, timings)
			task.wait(timings.CoverSeconds)
		end
		Debug.Log('EV', 'ending event', { event = id, source = src })
		_removeAssets()
		_restoreEnvironment()
		_restoreLights()
		_restoreTime()
		_current = nil
		EventService.ScheduleNext('event-end')
		Debug.Log('EV', 'event ended', { event = id })
		if not _suppressTransition then
			_broadcastTransition('Reveal', 'End', id, token, timings)
			_transitionId = nil
			startedToken = nil
		end
	end)
	if startedToken ~= nil then
		-- The body threw mid-transition (every cleanup path is
		-- idempotent + internally guarded, so this is
		-- unreachable in practice): reveal anyway — never trap
		-- clients white.
		_broadcastTransition('Reveal', 'End', 'unknown', startedToken, _transitionTimings())
		_transitionId = nil
	end
	return done
end

-- --- Tick ----------------------------------------------------------------------

local function _tick(dt: number)
	_accum += dt
	if _accum < 1 then
		return
	end
	_accum = 0
	pcall(function()
		local now = _serverNow()
		if _current ~= nil then
			if now >= (_current :: ActiveEvent).EndAt then
				EventService.EndEvent('schedule')
				return
			end
			-- Progressive mutation worker: evaluate eligible
			-- eggs every MutationIntervalSeconds (first cycle
			-- one full interval after start — never at start).
			-- Ending the event stops the worker by construction
			-- (no _current, no cycles).
			_mutAccum += 1
			local interval = 30
			pcall(function()
				local def = EventService.GetEvent((_current :: ActiveEvent).Id)
				if
					type(def) == 'table'
					and type(def.MutationIntervalSeconds) == 'number'
					and def.MutationIntervalSeconds >= 5
				then
					interval = def.MutationIntervalSeconds
				end
			end)
			if _mutAccum >= interval then
				_mutAccum = 0
				EventService.RunMutationCycle()
			end
			return
		end
		if _next ~= nil and now >= (_next :: NextEvent).At then
			local id = (_next :: NextEvent).Id
			if type(id) == 'string' and id ~= '' then
				local started = EventService.StartEvent(id, 'schedule')
				if not started then
					EventService.ScheduleNext('retry')
				end
			else
				EventService.ScheduleNext('cycle')
			end
		end
	end)
end

-- --- Init / Start -----------------------------------------------------------------

function EventService.Init()
	if _started then
		return
	end
	_started = true
	_services()
	-- NOTE: no spawn-bus subscription by design. New eggs join
	-- the ongoing process through the worker's next cycle
	-- (TryMutateEgg evaluates the live registry each time), so
	-- there is exactly one mutation path and nothing rolls at
	-- spawn or at event start.
	Debug.Log('EV', 'EventService initialized', {})
end

function EventService.Start()
	if _tickConn ~= nil then
		return
	end
	_tickConn = RunService.Heartbeat:Connect(_tick)
	EventService.ScheduleNext('boot')
	Debug.Log('EV', 'EventService started', {})
end

-- TEST seam: reset module state (specs only — production never
-- calls this; cleanup handles are dropped WITHOUT restoring,
-- so only use on a headless registry).
function EventService._TestReset()
	_current = nil
	_next = nil
	_assetClone = nil
	_envSnapshot = nil
	_savedClockTime = nil
	_revision = 0
	_testPlayerResolver = nil
	_mutAccum = 0
	_transitionSeq = 0
	_transitionId = nil
	_suppressTransition = false
	_testCoverOverride = nil
	_testBroadcasts = {}
	_lightsSnapshot = nil
	_testLightsRoots = nil
end

return table.freeze(EventService)
