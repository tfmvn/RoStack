--!strict
--!native
--[[
	ArenaBattleService
	==================
	Pure server-authoritative combat engine. Owns NO players,
	NO remotes, NO profiles, NO visuals — just temporary
	combatant tables driven by ONE centralized scheduler tick
	for every active battle on the server.

	Data flow:
	  ArenaService (sessions, validation, rewards, cleanup)
	        |
	        +-- creates battles here at Start (validated team +
	        |   config roster), registers them with the tick
	        +-- receives won/lost via the injected onBattleEnd
	            callback and settles exactly once

	Combatant (temporary, battle-scoped):
	  {
	    Id: string,            -- unique within the battle
	    Team: 'Player' | 'Enemy',
	    SourceAnimalId: string?, -- player animal UniqueId / nil
	    DefinitionId: string,
	    DisplayName: string,
	    Rarity: string?,       -- snapshot identity (display)
	    Trait: string?,        -- snapshot identity (display)
	    Mutations: { string }, -- snapshot identity (display)
	    OwnerUserId: number?,  -- snapshot identity (audit)
	    Level: number,
	    MaxHealth: number,
	    CurrentHealth: number, -- ONLY this mutates in combat
	    Damage: number,        -- ALWAYS MaxHealth-derived / 10
	    IsBoss: boolean,
	    PositionIndex: number, -- deterministic slot order
	    NextAttackAt: number,  -- os.clock gate
	    Alive: boolean,
	  }

	SNAPSHOT CONTRACT: combatants are built ONCE from the
	validated team member + canonical stats. The persistent
	record is never read again for this battle (no live stat
	polling), and combat Health is never written back.
	Trait/Mutations are identity carried for presentation;
	they never alter combat stats (the canonical layer
	already excludes them from Health/Damage).

	ATTACK ORDER (sequential turns): at most one attack per
	tick — Player side, then Enemy side, alternating, Player
	first. Within a side, living combatants rotate in
	PositionIndex order (dead never act). Successive turns
	gate behind TURN_INTERVAL. Same battle state (+ the
	deterministic animation PRNG) => same order. Damage/HP/
	death math is untouched by the choreography.

	Stat rule (never duplicated here): canonical Health via
	AnimalStats, then Damage = Health / 10. Enemy
	StatMultiplier scales HEALTH first; Damage derives from
	the scaled result, so FinalDamage * 10 == FinalHealth by
	construction. Traits/mutations never touch combat stats
	(the canonical layer already excludes them).

	Targeting (V1, deterministic, extensible): front-to-front
	by PositionIndex with first-alive fallback. pickTarget is
	the single seam future strategies plug into.

	Session safety: every tick re-validates through the
	injected validator (player present, base owned, session
	still active). Stale/invalid battles cancel silently with
	NO rewards. Tick + reward paths both guard on
	battle.state, so duplicate end-events can never double-pay.
]]

local ReplicatedStorage = game:GetService('ReplicatedStorage')
local RunService = game:GetService('RunService')
local Workspace = game:GetService('Workspace')
local Debris = game:GetService('Debris')
local TweenService = game:GetService('TweenService')

local Debug = require(ReplicatedStorage.Utility.Debug)
local AnimalStats = require(ReplicatedStorage.Utility.AnimalStats)
local AnimalConfig = require(ReplicatedStorage.Config.Creatures.Animals)
local ArenaPresentationConfig = require(ReplicatedStorage.Config.World.ArenaFeel)
local AnimalOverhead = require(script.Parent.Parent.Animal.AnimalOverhead)
local SlotMath = require(script.Parent.Parent.Animal.SlotMath)

local ArenaBattleService = {}

-- --- Tunables (read from ArenaConfig at battle creation) -------

local FALLBACK_COOLDOWN = 1.5
-- Centralized scheduler cadence + turn gap. Canonical source:
-- ArenaPresentationConfig.Combat (values preserved exactly).
local TICK_INTERVAL = ArenaPresentationConfig.Combat.TickInterval
local PRESENT = ArenaPresentationConfig

-- --- Injection -----------------------------------------------------

-- validateBattle(battle) -> boolean. ArenaService answers
-- from live session state (player present, base owned,
-- session still Active). A false answer cancels the battle
-- with no reward.
local validatorRef: ((any) -> boolean)? = nil
-- onBattleEnd(userId, sessionId, won:boolean,
-- stageGeneration:number?). ArenaService settles the stage
-- exactly once (reward / HP carry-over / advance / raid
-- end). The generation lets staged runs reject delayed
-- callbacks from a previous stage.
local onBattleEndRef: ((number, number, boolean, number?) -> ())? = nil
-- onBattleCancel(userId, sessionId, stageGeneration?).
-- ArenaService drops the session silently
-- (leave/base-loss/validator trip): no reward, no unlock,
-- models already destroyed here.
local onBattleCancelRef: ((number, number, number?) -> ())? = nil

function ArenaBattleService.SetValidator(fn: ((any) -> boolean)?)
	validatorRef = fn
end

function ArenaBattleService.SetOnBattleEnd(fn: ((number, number, boolean, number?) -> ())?)
	onBattleEndRef = fn
end

function ArenaBattleService.SetOnBattleCancel(fn: ((number, number, number?) -> ())?)
	onBattleCancelRef = fn
end

-- eventSink(userId, event): presentation/log feed. ArenaService
-- logs + fires ArenaCombatEvent to the player. Engine never
-- blocks on it (pcall-guarded at every call site).
local eventSinkRef: ((number, { [string]: any }) -> ())? = nil
-- animalService for live-model clones + template lookups.
local animalServiceRef: any = nil

function ArenaBattleService.SetEventSink(fn: ((number, { [string]: any }) -> ())?)
	eventSinkRef = fn
end

function ArenaBattleService.SetAnimalService(svc: any)
	animalServiceRef = svc
end

local function emitEvent(battle: { [string]: any }, event: { [string]: any })
	if eventSinkRef == nil or type(battle) ~= 'table' then
		return
	end
	event.SessionId = battle.sessionId
	if battle.stageGeneration ~= nil then
		event.StageGeneration = battle.stageGeneration
	end
	pcall(eventSinkRef, battle.userId, event)
end

-- HIT_CONTACT fan-out: fires the single authoritative hit
-- packet at the contact moment (called from the attack
-- thread, never from the tick). Session-safe: the battle
-- must still be Active — a finished/cancelled battle never
-- presents. ArenaService broadcasts these to every client;
-- all other events stay owner-targeted.
local function emitHitEvent(battle: { [string]: any }, payload: { [string]: any })
	if eventSinkRef == nil or type(battle) ~= 'table' or type(payload) ~= 'table' then
		return
	end
	if battle.state ~= 'Active' then
		return
	end
	payload.SessionId = battle.sessionId
	if battle.stageGeneration ~= nil then
		payload.StageGeneration = battle.stageGeneration
	end
	if type(battle.userId) == 'number' then
		payload.OwnerUserId = battle.userId
	end
	pcall(eventSinkRef, battle.userId, payload)
end

-- --- Internal state --------------------------------------------------

-- [userId] -> battle. One battle per player max (ArenaService
-- rejects duplicate starts before we ever see them).
local battles: { [number]: { [string]: any } } = {}
local schedulerConn: RBXScriptConnection? = nil
local combatantSeq = 0

-- --- Combatant builders (pure) -----------------------------------------

local function nextCombatantId(team: string, index: number): string
	combatantSeq += 1
	return ('%s-%d-%d'):format(team, index, combatantSeq)
end

-- Player combatant from a validated ResolveArenaTeam member.
-- Canonical stats only; persistent record untouched.
-- `hpOverride` (optional): carried raid HP for a continuing
-- run. Nil = fresh combatant at full health. A provided
-- value is clamped into [0, MaxHealth]; 0 means the
-- combatant enters dead (Alive = false) and is skipped by
-- spawning/targeting/acting, but stays listed for UI.
function ArenaBattleService.BuildPlayerCombatant(
	member: any,
	positionIndex: number,
	now: number,
	cooldown: number,
	hpOverride: number?
): (any?, string?)
	if type(member) ~= 'table' then
		return nil, 'bad-member'
	end
	if type(member.DefinitionId) ~= 'string' or member.DefinitionId == '' then
		return nil, 'bad-definition'
	end
	local level = member.Level
	if type(level) ~= 'number' or level ~= math.floor(level) or level < 1 then
		return nil, 'bad-level'
	end
	local health: number? = nil
	local damage: number? = nil
	local okH, h = pcall(AnimalStats.Calculate, { DefId = member.DefinitionId, Level = level }, 'Health')
	if okH and type(h) == 'number' and h == h and h > 0 then
		health = h
	end
	local okD, d = pcall(AnimalStats.Calculate, { DefId = member.DefinitionId, Level = level }, 'Damage')
	if okD and type(d) == 'number' and d == d and d > 0 then
		damage = d
	end
	if health == nil or damage == nil then
		return nil, 'stat-failed'
	end
	-- Identity snapshot (display/audit only): Trait /
	-- Mutations / Rarity / owner ride along for overheads and
	-- logs but NEVER feed stat math above.
	local trait: string? = nil
	if type(member.Trait) == 'string' then
		trait = member.Trait
	end
	local mutations: { string } = {}
	if type(member.Mutations) == 'table' then
		for _, id in ipairs(member.Mutations) do
			if type(id) == 'string' then
				mutations[#mutations + 1] = id
			end
		end
	end
	local rarity: string? = nil
	if type(member.Rarity) == 'string' then
		rarity = member.Rarity
	end
	local owner: number? = nil
	if type(member.OwnerUserId) == 'number' then
		owner = member.OwnerUserId
	end
	-- Raid carry-over: current HP is run state owned by the
	-- raid session, never recomputed here. Fresh combatants
	-- start full; continuing ones start exactly where the
	-- previous stage left them (0 = dead for the run).
	local currentHealth = health
	local alive = true
	if hpOverride ~= nil then
		if type(hpOverride) ~= 'number' or hpOverride ~= hpOverride then
			return nil, 'bad-hp-override'
		end
		currentHealth = math.clamp(hpOverride, 0, health)
		alive = currentHealth > 0
	end
	return {
		Id = nextCombatantId('P', positionIndex),
		Team = 'Player',
		SourceAnimalId = member.UniqueId,
		DefinitionId = member.DefinitionId,
		DisplayName = member.DisplayName or member.DefinitionId,
		Rarity = rarity,
		Trait = trait,
		Mutations = mutations,
		OwnerUserId = owner,
		Level = level,
		MaxHealth = health,
		CurrentHealth = currentHealth,
		Damage = damage,
		IsBoss = false,
		PositionIndex = positionIndex,
		NextAttackAt = now + cooldown,
		Alive = alive,
	},
		nil
end

-- Enemy combatant from an ArenaConfig enemy def. Canonical
-- stats first, StatMultiplier on HEALTH, Damage derived —
-- invariant holds by construction.
function ArenaBattleService.BuildEnemyCombatant(
	enemyDef: any,
	positionIndex: number,
	now: number,
	cooldown: number
): (any?, string?)
	if type(enemyDef) ~= 'table' then
		return nil, 'bad-enemy'
	end
	if type(enemyDef.DefinitionId) ~= 'string' or enemyDef.DefinitionId == '' then
		return nil, 'bad-definition'
	end
	local level = enemyDef.Level
	if type(level) ~= 'number' or level ~= math.floor(level) or level < 1 then
		return nil, 'bad-level'
	end
	local mult = if enemyDef.StatMultiplier == nil then 1 else enemyDef.StatMultiplier
	if type(mult) ~= 'number' or mult ~= mult or mult <= 0 then
		return nil, 'bad-multiplier'
	end
	local base: number? = nil
	local okH, h = pcall(AnimalStats.Calculate, { DefId = enemyDef.DefinitionId, Level = level }, 'Health')
	if okH and type(h) == 'number' and h == h and h > 0 then
		base = h
	end
	if base == nil then
		return nil, 'stat-failed'
	end
	local finalHealth = (base :: number) * mult
	local finalDamage = finalHealth / 10
	return {
		Id = nextCombatantId('E', positionIndex),
		Team = 'Enemy',
		SourceAnimalId = nil,
		DefinitionId = enemyDef.DefinitionId,
		DisplayName = enemyDef.DisplayName or enemyDef.DefinitionId,
		Level = level,
		MaxHealth = finalHealth,
		CurrentHealth = finalHealth,
		Damage = finalDamage,
		IsBoss = enemyDef.IsBoss == true,
		PositionIndex = positionIndex,
		NextAttackAt = now + cooldown,
		Alive = true,
	},
		nil
end

-- --- Battle lifecycle (pure-ish: no services, no remotes) ---------------

-- Create a battle from validated inputs. Returns battle or
-- (nil, error). Both teams must be non-empty; every
-- combatant must build or the whole battle is refused
-- (never a half-built fight). `stageGeneration` (optional)
-- tags the battle for stale-callback validation in staged
-- runs. `hpBySource` (optional, {[SourceAnimalId]=hp})
-- carries raid HP into player combatants; at least one
-- player combatant must enter alive or the battle is
-- refused with 'all-dead' (the raid, not a new fight,
-- owns that terminal state).
function ArenaBattleService.CreateBattle(
	userId: number,
	sessionId: number,
	arenaLevel: number,
	playerMembers: { any },
	enemyDefs: { any },
	cooldown: number,
	now: number,
	stageGeneration: number?,
	hpBySource: { [string]: number }?
): (any?, string?)
	if type(userId) ~= 'number' or type(sessionId) ~= 'number' then
		return nil, 'bad-ids'
	end
	if type(playerMembers) ~= 'table' or #playerMembers < 1 then
		return nil, 'empty-player-team'
	end
	if type(enemyDefs) ~= 'table' or #enemyDefs < 1 then
		return nil, 'empty-enemy-team'
	end
	if type(cooldown) ~= 'number' or cooldown ~= cooldown or cooldown <= 0 then
		cooldown = FALLBACK_COOLDOWN
	end
	local playerTeam: { any } = {}
	for i, member in ipairs(playerMembers) do
		local override: number? = nil
		if type(hpBySource) == 'table' and type(member) == 'table' and type(member.UniqueId) == 'string' then
			local carried = hpBySource[member.UniqueId]
			if type(carried) == 'number' then
				override = carried
			end
		end
		local combatant, err = ArenaBattleService.BuildPlayerCombatant(member, i, now, cooldown, override)
		if combatant == nil then
			return nil, 'player-combatant-failed:' .. tostring(err)
		end
		playerTeam[#playerTeam + 1] = combatant
	end
	local anyAlive = false
	for _, combatant in ipairs(playerTeam) do
		if combatant.Alive == true then
			anyAlive = true
			break
		end
	end
	if not anyAlive then
		return nil, 'all-dead'
	end
	local enemyTeam: { any } = {}
	for i, enemyDef in ipairs(enemyDefs) do
		local combatant, err = ArenaBattleService.BuildEnemyCombatant(enemyDef, i, now, cooldown)
		if combatant == nil then
			return nil, 'enemy-combatant-failed:' .. tostring(err)
		end
		enemyTeam[#enemyTeam + 1] = combatant
	end
	-- Sequential turn state: Player opens, first strike is
	-- immediate (nextTurnAt = now) so fights start promptly.
	-- animSeed derives from the battle identity: distinct
	-- battles open on distinct animations, identical inputs
	-- replay identically.
	local animSeed = 1
	pcall(function()
		local computed = ((userId * 31 + sessionId) * 31 + arenaLevel) % 2147483647
		if type(computed) == 'number' and computed == computed and computed >= 1 then
			animSeed = math.floor(computed)
		end
	end)
	return {
		userId = userId,
		sessionId = sessionId,
		arenaLevel = arenaLevel,
		stageGeneration = stageGeneration,
		state = 'Active',
		cooldown = cooldown,
		playerTeam = playerTeam,
		enemyTeam = enemyTeam,
		startedAt = now,
		finishedAt = nil,
		result = nil,
		turnSide = 'Player',
		turnCursor = { Player = 1, Enemy = 1 },
		nextTurnAt = if type(now) == 'number' then now else 0,
		lastAnimation = 0,
		animSeed = animSeed,
		soundCursor = 1,
		attackSeq = 0,
		-- Damage contribution ledger for this stage battle:
		-- {[player SourceAnimalId] = actual HP damage applied}.
		-- TickBattle records clamped (overkill-safe) damage here;
		-- ArenaService carries it into the raid session so the
		-- terminal XP split is proportional to real damage.
		damageBySource = {},
		-- Result keepsakes for this stage battle: {[combatant Id]
		-- = pristine pre-destruction clone of a PLAYER combatant's
		-- combat model}. Captured at death (before the death fade
		-- destroys the model) and at stage end (survivors, before
		-- advance/terminal cleanup). ArenaService merges these
		-- into the raid session keyed by SourceAnimalId, so every
		-- participant — dead or alive — has its ACTUAL combat
		-- model available for the ArenaResult viewport.
		keepsakeModels = {},
	},
		nil
end

function ArenaBattleService.GetBattle(userId: number): { [string]: any }?
	if type(userId) ~= 'number' then
		return nil
	end
	return battles[userId]
end

-- Front-to-front by PositionIndex; the same-index living
-- enemy when possible, else the first living enemy. Never
-- targets dead/nil; deterministic extension seam for
-- nearest/lowest/random strategies.
function ArenaBattleService.PickTarget(battle: { [string]: any }, attacker: { [string]: any }): { [string]: any }?
	if type(battle) ~= 'table' or type(attacker) ~= 'table' then
		return nil
	end
	local foes = if attacker.Team == 'Player' then battle.enemyTeam else battle.playerTeam
	if type(foes) ~= 'table' then
		return nil
	end
	local fallback: { [string]: any }? = nil
	for _, foe in ipairs(foes) do
		if type(foe) == 'table' and foe.Alive == true and (foe.CurrentHealth or 0) > 0 then
			if fallback == nil then
				fallback = foe
			end
			if foe.PositionIndex == attacker.PositionIndex then
				return foe
			end
		end
	end
	return fallback
end

local function teamAlive(team: { any }): boolean
	if type(team) ~= 'table' then
		return false
	end
	for _, combatant in ipairs(team) do
		if type(combatant) == 'table' and combatant.Alive == true and (combatant.CurrentHealth or 0) > 0 then
			return true
		end
	end
	return false
end

-- --- Sequential turn choreography --------------------------------------
--
-- One attack per turn, strictly alternating Player -> Enemy ->
-- Player ... (Player opens). Within a side, living combatants
-- rotate in PositionIndex order; the dead are skipped and can
-- never act. Successive turns gate behind TURN_INTERVAL so
-- each attack animation reads cleanly before the next begins.
-- Damage authority is unchanged (same Damage/HP/death math as
-- the old simultaneous loop — only the sequencing is new).
--
-- Per-battle turn state (initialized in CreateBattle):
--   turnSide: 'Player' | 'Enemy' (side to move)
--   turnCursor: { Player = n, Enemy = n } (round-robin index
--     into PositionIndex order, 1-based)
--   nextTurnAt: number (earliest `now` that may execute)
--   lastAnimation: number (previous attack-animation index,
--     0 = none yet — drives the no-immediate-repeat rule)
--   animSeed: number (deterministic per-battle PRNG state,
--     presentation-only: sim values never flow through it)
-- Full-travel choreography budget: 0.3 travel + ~0.3 attack
-- flourish + 0.3 return + margin. Sequential by construction
-- (every program above runs shorter than this).
-- Canonical: ArenaPresentationConfig.Combat.TurnInterval.
local TURN_INTERVAL = PRESENT.Combat.TurnInterval
local ATTACK_ANIMATION_COUNT = 5

-- Deterministic per-battle PRNG (Numerical Recipes LCG with
-- explicit 2^32 wrap — Lua doubles hold every intermediate
-- exactly). Every observer of the same battle sees the same
-- animation sequence, and specs can assert variety without
-- flakes. Consecutive repeats are re-rolled once, so variety
-- over successive attacks is structural.
local function _nextAnimIndex(battle: { [string]: any }): number
	local seed = tonumber(battle.animSeed) or 1
	if seed ~= seed or seed < 1 then
		seed = 1
	end
	seed = (1664525 * (seed % 4294967296) + 1013904223) % 4294967296
	battle.animSeed = seed
	local idx = (seed % ATTACK_ANIMATION_COUNT) + 1
	if idx == battle.lastAnimation then
		idx = (idx % ATTACK_ANIMATION_COUNT) + 1
	end
	battle.lastAnimation = idx
	return idx
end

-- Next living attacker for `side` in round-robin PositionIndex
-- order starting at the side cursor (wrapping). Advances the
-- cursor past the returned attacker. Nil when the side has
-- nobody standing.
local function nextTurnAttacker(battle: { [string]: any }, side: string): { [string]: any }?
	local team = if side == 'Player' then battle.playerTeam else battle.enemyTeam
	if type(team) ~= 'table' or #team < 1 then
		return nil
	end
	local ordered: { any } = {}
	for _, c in ipairs(team) do
		ordered[#ordered + 1] = c
	end
	table.sort(ordered, function(a: any, b: any)
		return ((type(a) == 'table' and a.PositionIndex) or 0) < ((type(b) == 'table' and b.PositionIndex) or 0)
	end)
	local cursor = 1
	if type(battle.turnCursor) == 'table' then
		local cur = tonumber(battle.turnCursor[side]) or 1
		if cur == cur and cur >= 1 and cur <= #ordered then
			cursor = math.floor(cur)
		end
	end
	for step = 0, #ordered - 1 do
		local combatant = ordered[((cursor - 1 + step) % #ordered) + 1]
		if type(combatant) == 'table' and combatant.Alive == true and (combatant.CurrentHealth or 0) > 0 then
			if type(battle.turnCursor) == 'table' then
				battle.turnCursor[side] = ((cursor - 1 + step + 1) % #ordered) + 1
			end
			return combatant
		end
	end
	return nil
end

-- Authoritative contact point for an attacker->target pair:
-- the target's canonical body CENTER (target HomeCFrame
-- position — never live pivots, so the scheduler, the VFX
-- placement, and the client event all agree). The previous
-- revision offset outward by the target's body radius toward
-- the attacker (attacker-facing surface point); for small
-- animals that offset lands outside the part (radius 2.5 vs a
-- 2-stud body) so Attack1 floated beside the model instead of
-- on it. Centering puts the burst on/in the target for every
-- body size. Nil when either home is unknown (headless/test
-- battles) — callers degrade gracefully.
local function computeContactPoint(attacker: { [string]: any }, target: { [string]: any }): Vector3?
	if type(attacker) ~= 'table' or type(target) ~= 'table' then
		return nil
	end
	local tHome = target.HomeCFrame
	if typeof(tHome) ~= 'CFrame' then
		return nil
	end
	if typeof(attacker.HomeCFrame) ~= 'CFrame' then
		return nil
	end
	return (tHome :: CFrame).Position
end

-- Advance one battle to `now`. Executes AT MOST one attack:
-- the current turn side's next living combatant strikes one
-- living target (existing PickTarget rules), then the side
-- flips and the next turn gates behind nextTurnAt. Returns
-- { events, finished } with at most one 'attack' (+ optional
-- 'defeat') event. finished is 'won' | 'lost' | nil. A
-- finished battle ticks no further (caller unregisters on
-- finish). No yields inside: attacker/target/liveness are
-- decided atomically, so a target can never die between
-- selection and damage within a tick.
function ArenaBattleService.TickBattle(battle: { [string]: any }, now: number): { [string]: any }
	local outcome: { [string]: any } = { events = {}, finished = nil }
	if type(battle) ~= 'table' or battle.state ~= 'Active' then
		return outcome
	end
	if type(now) ~= 'number' then
		return outcome
	end
	if now < (tonumber(battle.nextTurnAt) or 0) then
		return outcome
	end
	local side = if battle.turnSide == 'Enemy' then 'Enemy' else 'Player'
	local attacker = nextTurnAttacker(battle, side)
	if attacker == nil then
		-- This side has nobody standing: the battle is over,
		-- and the wiped side can never act again.
		if side == 'Player' then
			battle.state = 'Lost'
			battle.finishedAt = now
			battle.result = 'lost'
			outcome.finished = 'lost'
		else
			battle.state = 'Won'
			battle.finishedAt = now
			battle.result = 'won'
			outcome.finished = 'won'
		end
		return outcome
	end
	local target = ArenaBattleService.PickTarget(battle, attacker)
	if target == nil then
		-- Opposing team already fully wiped: record the
		-- matching terminal for this side's attack.
		if side == 'Player' then
			battle.state = 'Won'
			battle.finishedAt = now
			battle.result = 'won'
			outcome.finished = 'won'
		else
			battle.state = 'Lost'
			battle.finishedAt = now
			battle.result = 'lost'
			outcome.finished = 'lost'
		end
		return outcome
	end
	local damage = attacker.Damage
	if type(damage) ~= 'number' or damage ~= damage or damage < 0 then
		damage = 0
	end
	-- Damage contribution (player team only): the ACTUAL HP
	-- removed, clamped to the target's remaining health so
	-- overkill never inflates a share (10 HP left + 25 attack
	-- = 10 contribution). Keyed by SourceAnimalId (the
	-- persistent animal UniqueId), never DefId, so duplicate
	-- species stay individually trackable. Dead animals keep
	-- whatever they earned while alive — this ledger only grows.
	local healthBefore = tonumber(target.CurrentHealth) or 0
	if healthBefore ~= healthBefore or healthBefore < 0 then
		healthBefore = 0
	end
	target.CurrentHealth = math.max(0, healthBefore - damage)
	if attacker.Team == 'Player' and type(attacker.SourceAnimalId) == 'string' then
		local applied = math.min(damage, healthBefore)
		if applied > 0 then
			if type(battle.damageBySource) ~= 'table' then
				battle.damageBySource = {}
			end
			local key = attacker.SourceAnimalId
			battle.damageBySource[key] = (tonumber(battle.damageBySource[key]) or 0) + applied
			-- Per-hit contribution trace (one line per player
			-- attack, not per frame): attacker share + team
			-- running total for this stage battle.
			local runningTotal = 0
			for _, amt in pairs(battle.damageBySource) do
				if type(amt) == 'number' and amt > 0 then
					runningTotal += amt
				end
			end
						Debug.Warn('ArenaDamage', ('session=%s attacker=%s appliedDamage=%d totalDamage=%d'):format(
					tostring(battle.sessionId),
					tostring(key),
					math.floor(applied),
					math.floor(runningTotal)
				))
		end
	end
	-- NextAttackAt is kept as a diagnostic "last acted" stamp
	-- (turn gating owns scheduling now).
	attacker.NextAttackAt = now + (battle.cooldown or FALLBACK_COOLDOWN)
	local anim = _nextAnimIndex(battle)
	-- Deterministic per-battle sound cycle 1 -> 2 -> 3,
	-- advanced here authoritatively so every observer (and
	-- the impact thread) agrees on which sound this hit owns.
	local soundIdx = tonumber(battle.soundCursor) or 1
	if soundIdx ~= soundIdx or soundIdx < 1 or soundIdx > 3 then
		soundIdx = 1
	end
	soundIdx = math.floor(soundIdx)
	battle.soundCursor = (soundIdx % 3) + 1
	local seq = (tonumber(battle.attackSeq) or 0) + 1
	battle.attackSeq = seq
	outcome.events[#outcome.events + 1] = {
		type = 'attack',
		attackerId = attacker.Id,
		attackerTeam = attacker.Team,
		targetId = target.Id,
		targetTeam = target.Team,
		damage = damage,
		targetHealth = target.CurrentHealth,
		targetMaxHealth = target.MaxHealth,
		attackAnimation = anim,
		soundIndex = soundIdx,
		attackSequence = seq,
		impactPosition = computeContactPoint(attacker, target),
	}
	if target.CurrentHealth <= 0 and target.Alive ~= false then
		target.Alive = false
		outcome.events[#outcome.events + 1] = {
			type = 'defeat',
			targetId = target.Id,
			targetTeam = target.Team,
		}
	end
	if not teamAlive(battle.enemyTeam) then
		battle.state = 'Won'
		battle.finishedAt = now
		battle.result = 'won'
		outcome.finished = 'won'
		return outcome
	end
	if not teamAlive(battle.playerTeam) then
		battle.state = 'Lost'
		battle.finishedAt = now
		battle.result = 'lost'
		outcome.finished = 'lost'
		return outcome
	end
	battle.nextTurnAt = now + TURN_INTERVAL
	battle.turnSide = if side == 'Player' then 'Enemy' else 'Player'
	return outcome
end

-- --- Centralized scheduler (ONE Heartbeat, all battles) --------------------

local function stopScheduler()
	if schedulerConn ~= nil then
		pcall(function()
			(schedulerConn :: RBXScriptConnection):Disconnect()
		end)
		schedulerConn = nil
	end
end

local function ensureScheduler()
	if schedulerConn ~= nil then
		return
	end
	local lastTick = 0
	local ok, conn = pcall(function()
		return RunService.Heartbeat:Connect(function()
			local now = os.clock()
			if now - lastTick < TICK_INTERVAL then
				return
			end
			lastTick = now
			ArenaBattleService.TickAll(now)
		end)
	end)
	if ok and conn ~= nil then
		schedulerConn = conn
	end
end

function ArenaBattleService.RegisterBattle(battle: { [string]: any }): boolean
	if type(battle) ~= 'table' or type(battle.userId) ~= 'number' then
		return false
	end
	if battle.state ~= 'Active' then
		return false
	end
	battles[battle.userId] = battle
	ensureScheduler()
	return true
end

function ArenaBattleService.UnregisterBattle(userId: number)
	if type(userId) ~= 'number' then
		return
	end
	battles[userId] = nil
	local empty = true
	for _ in pairs(battles) do
		empty = false
		break
	end
	if empty then
		stopScheduler()
	end
end

-- Single-battle tick body (validate -> advance -> present ->
-- settle/cancel). Runs inside TickAll's per-battle pcall.
-- Presentation lookups resolve at call time, so this stays
-- above TickAll for readability.
local function tickOneBattle(userId: number, battle: { [string]: any }, now: number)
	local valid = false
	pcall(function()
		if validatorRef then
			valid = validatorRef(battle) == true
		end
	end)
	if not valid then
		battles[userId] = nil
		ArenaBattleService.DestroyBattleModels(battle)
		emitEvent(battle, { Event = 'Cancelled' })
		if onBattleCancelRef then
			pcall(onBattleCancelRef, userId, battle.sessionId, battle.stageGeneration)
		end
		return
	end
	local outcome: { [string]: any } = { events = {}, finished = nil }
	pcall(function()
		outcome = ArenaBattleService.TickBattle(battle, now)
	end)
	if type(outcome.events) == 'table' then
		-- Impact staging: a defeat in this tick always follows
		-- its attack, so it shares the same impact delay — the
		-- death fade starts exactly when the hit bundle lands.
		-- (Damage numbers/VFX/sound now present client-side
		-- from the ArenaHit packet; the server keeps motion,
		-- flash, reaction, and death only.)
		local impactAt = 0
		for _, event in ipairs(outcome.events) do
			if type(event) == 'table' then
				if event.type == 'attack' then
					impactAt = ArenaBattleService.PresentAttack(battle, event)
										Debug.Warn('ArenaHit', ('session=%s attacker=%s target=%s damage=%s attackIndex=%s soundIndex=%s seq=%s impact=%s'):format(
							tostring(battle.sessionId),
							tostring(event.attackerId),
							tostring(event.targetId),
							tostring(event.damage),
							tostring(event.attackAnimation),
							tostring(event.soundIndex),
							tostring(event.attackSequence),
							tostring(event.impactPosition)
						))
				elseif event.type == 'defeat' then
					ArenaBattleService.PresentDeath(battle, event.targetId, impactAt)
				end
				emitEvent(battle, event)
			end
		end
	end
	if outcome.finished == 'won' or outcome.finished == 'lost' then
		battles[userId] = nil
		emitEvent(battle, { Event = if outcome.finished == 'won' then 'Victory' else 'Defeat' })
		if onBattleEndRef then
			pcall(onBattleEndRef, userId, battle.sessionId, outcome.finished == 'won', battle.stageGeneration)
		end
	end
end

-- One tick for every registered battle: re-validate,
-- advance, present each event (models/overheads), forward
-- events to the sink, and settle finished battles exactly
-- once via the injected end callback. Stale/invalid battles
-- cancel with NO reward path (ArenaService only rewards
-- explicit wins).
--
-- CONCURRENCY CONTRACT: the key set is snapshotted before
-- iterating (battles unregister mid-pass on finish/cancel —
-- mutating a table during pairs traversal can skip entries),
-- and each battle ticks inside its own pcall. A throw in one
-- player's battle (broken model, bad overhead) can never
-- starve another player's battle: the error is logged and
-- the loop continues to the next session.
function ArenaBattleService.TickAll(now: number)
	local keys: { number } = {}
	for userId in pairs(battles) do
		keys[#keys + 1] = userId
	end
	table.sort(keys)
	for _, userId in ipairs(keys) do
		local battle = battles[userId]
		if battle ~= nil then
			local ok, err = pcall(tickOneBattle, userId, battle, now)
			if not ok then
				warn(
					('[Arena] Battle tick failed user=%s session=%s (other sessions continue): %s'):format(
						tostring(userId),
						tostring((type(battle) == 'table' and battle.sessionId) or '?'),
						tostring(err)
					)
				)
			end
		end
	end
	local empty = true
	for _ in pairs(battles) do
		empty = false
		break
	end
	if empty then
		stopScheduler()
	end
end

-- --- Presentation: authored markers, temp models, effects ------------
--
-- Authored structure (per player base, Studio-authored):
--   Base_X/Arena/
--     PlayerSpawns/Position<N> (BasePart | Attachment | Model)
--     EnemySpawns/Position<N>  (BasePart | Attachment | Model)
--   Base/Arena/Center is used by area discovery; BossSpawn is
--   reserved (bosses take EnemyPositions slots in V1).
-- Nothing here invents coordinates: missing markers fail the
-- battle start loudly via ResolveBattlePositions.

local function markerCFrame(node: Instance?): CFrame?
	if node == nil then
		return nil
	end
	local cf: CFrame? = nil
	pcall(function()
		if (node :: Instance):IsA('BasePart') then
			cf = (node :: BasePart).CFrame
		elseif (node :: Instance):IsA('Attachment') then
			cf = (node :: Attachment).WorldCFrame
		elseif (node :: Instance):IsA('Model') then
			cf = (node :: Model):GetPivot()
		end
	end)
	return cf
end

-- Ground surface point for one spawn marker: the TOP face
-- for BaseParts (center + up * half-height, rotation-aware),
-- the bare point for Attachments/Models (no surface exists).
-- Never throws; nil when the node is unusable.
local function markerSurface(node: Instance?): Vector3?
	if node == nil then
		return nil
	end
	local top: Vector3? = nil
	pcall(function()
		if (node :: Instance):IsA('BasePart') then
			local part = node :: BasePart
			top = part.CFrame.Position + part.CFrame.UpVector * (part.Size.Y / 2)
		elseif (node :: Instance):IsA('Attachment') then
			top = (node :: Attachment).WorldPosition
		elseif (node :: Instance):IsA('Model') then
			top = ((node :: Model):GetPivot()).Position
		end
	end)
	return top
end

-- Indexed spawn children (trailing digits, numeric sort) of a
-- marker folder. Returns { cf, surface } entries in
-- deterministic order: `cf` is the marker transform (X/Z +
-- facing source, UNCHANGED shape for existing callers),
-- `surface` is the ground-plane point the model's bottom
-- must sit on.
local function collectSpawns(container: Instance?): { { cf: CFrame, surface: Vector3? } }
	local out: { { cf: CFrame, surface: Vector3? } } = {}
	if container == nil then
		return out
	end
	local ordered: { any } = {}
	pcall(function()
		for _, child in ipairs((container :: Instance):GetChildren()) do
			local num = tonumber(string.match(child.Name, '(%d+)$'))
			if num ~= nil then
				local cf = markerCFrame(child)
				if cf ~= nil then
					ordered[#ordered + 1] = { index = num, cf = cf, surface = markerSurface(child) }
				end
			end
		end
	end)
	table.sort(ordered, function(a: any, b: any)
		return a.index < b.index
	end)
	for _, entry in ipairs(ordered) do
		out[#out + 1] = { cf = entry.cf, surface = entry.surface }
	end
	return out
end

-- Resolve battle positions for a base + team sizes. Fails
-- closed with an explicit missing list (caller rejects the
-- battle start — never a fake fight). `player`/`enemy` stay
-- plain CFrame arrays (existing callers + specs untouched);
-- the parallel `playerSurface`/`enemySurface` arrays carry
-- each marker's ground-plane point for model grounding.
function ArenaBattleService.ResolveBattlePositions(
	base: any,
	playerCount: number,
	enemyCount: number
): { [string]: any }
	local missing: { string } = {}
	local player: { CFrame } = {}
	local enemy: { CFrame } = {}
	local playerSurface: { Vector3? } = {}
	local enemySurface: { Vector3? } = {}
	local function emptyResult(ready: boolean): { [string]: any }
		return {
			ready = ready,
			player = player,
			enemy = enemy,
			playerSurface = playerSurface,
			enemySurface = enemySurface,
			missing = missing,
		}
	end
	if type(base) ~= 'table' or typeof(base.folder) ~= 'Instance' then
		missing[#missing + 1] = 'base folder'
		return emptyResult(false)
	end
	local folder = base.folder :: Instance
	local area: Instance? = nil
	pcall(function()
		area = folder:FindFirstChild('Arena')
	end)
	if area == nil then
		missing[#missing + 1] = folder:GetFullName() .. '/Arena (folder)'
		return emptyResult(false)
	end
	local playerSpawns: Instance? = nil
	local enemySpawns: Instance? = nil
	pcall(function()
		playerSpawns = (area :: Instance):FindFirstChild('PlayerSpawns')
		enemySpawns = (area :: Instance):FindFirstChild('EnemySpawns')
	end)
	if playerSpawns == nil then
		missing[#missing + 1] = 'Arena/PlayerSpawns (folder)'
	end
	if enemySpawns == nil then
		missing[#missing + 1] = 'Arena/EnemySpawns (folder)'
	end
	for _, spot in ipairs(collectSpawns(playerSpawns)) do
		player[#player + 1] = spot.cf
		playerSurface[#playerSurface + 1] = spot.surface
	end
	for _, spot in ipairs(collectSpawns(enemySpawns)) do
		enemy[#enemy + 1] = spot.cf
		enemySurface[#enemySurface + 1] = spot.surface
	end
	for i = #player + 1, playerCount do
		missing[#missing + 1] = ('Arena/PlayerSpawns/Position%d'):format(i)
	end
	for i = #enemy + 1, enemyCount do
		missing[#missing + 1] = ('Arena/EnemySpawns/Position%d'):format(i)
	end
	return emptyResult(#missing == 0)
end

local function findCombatant(battle: { [string]: any }, combatantId: string): { [string]: any }?
	if type(battle) ~= 'table' or type(combatantId) ~= 'string' then
		return nil
	end
	for _, team in ipairs({ battle.playerTeam, battle.enemyTeam }) do
		if type(team) == 'table' then
			for _, c in ipairs(team) do
				if type(c) == 'table' and c.Id == combatantId then
					return c
				end
			end
		end
	end
	return nil
end

local function liveModel(combatant: { [string]: any }): Model?
	if type(combatant) ~= 'table' then
		return nil
	end
	local model = combatant.Model
	if typeof(model) == 'Instance' and (model :: Instance):IsA('Model') and (model :: Model).Parent ~= nil then
		return model
	end
	return nil
end

-- Prepare a combat clone: strip interactive/duplicate UI
-- (prompts, stale overheads), freeze physics (server moves
-- models via PivotTo only), silence collisions.
local function prepCombatModel(model: Model, name: string)
	pcall(function()
		for _, desc in ipairs(model:GetDescendants()) do
			-- Stale interactive/duplicate UI must never ride
			-- along on a combat clone.
			if
				desc:IsA('ProximityPrompt')
				or (desc:IsA('BillboardGui') and (desc.Name == 'OverheadGui' or desc.Name == 'OverheadTemplate'))
			then
				desc:Destroy()
			end
		end
		for _, desc in ipairs(model:GetDescendants()) do
			if desc:IsA('BasePart') then
				desc.Anchored = true
				desc.CanCollide = false
				desc.CanTouch = false
			end
		end
		model.Name = name
	end)
end

local function cloneLiveAnimalModel(combatant: { [string]: any }): (Model?, string?)
	if not animalServiceRef or not animalServiceRef.Get then
		return nil, 'no-animal-service'
	end
	local animal: any = nil
	pcall(function()
		animal = animalServiceRef.Get(combatant.SourceAnimalId)
	end)
	if type(animal) ~= 'table' then
		return nil, 'persistent-animal-gone'
	end
	local source = animal.model
	if typeof(source) ~= 'Instance' or not (source :: Instance):IsA('Model') or (source :: Model).Parent == nil then
		return nil, 'persistent-model-gone'
	end
	-- CLONE, never move: the stand animal stays exactly where
	-- the player left it.
	local clone: Model? = nil
	pcall(function()
		clone = (source :: Model):Clone()
	end)
	if clone == nil then
		return nil, 'clone-failed'
	end
	return clone, nil
end

local function cloneTemplateModel(definitionId: string, trait: string?): (Model?, string?)
	if not animalServiceRef or not animalServiceRef.GetTemplate then
		return nil, 'no-animal-service'
	end
	local rarity: string? = nil
	pcall(function()
		rarity = AnimalConfig.Get(definitionId)
	end)
	if type(rarity) ~= 'string' then
		return nil, 'unknown-definition'
	end
	local template: Model? = nil
	pcall(function()
		template = animalServiceRef.GetTemplate(rarity, definitionId, trait)
	end)
	if template == nil then
		return nil, 'template-missing'
	end
	local clone: Model? = nil
	pcall(function()
		clone = (template :: Model):Clone()
	end)
	if clone == nil then
		return nil, 'clone-failed'
	end
	return clone, nil
end

local function battleRootFolder(): Folder?
	local root: Folder? = nil
	pcall(function()
		root = Workspace:FindFirstChild('ArenaBattles')
		if root == nil then
			local created = Instance.new('Folder')
			created.Name = 'ArenaBattles'
			created.Parent = Workspace
			root = created
		end
	end)
	return root
end

local function refreshCombatantOverhead(combatant: { [string]: any })
	if type(combatant) ~= 'table' then
		return
	end
	local record = combatant.overheadRecord
	local model = liveModel(combatant)
	if type(record) ~= 'table' or model == nil then
		return
	end
	record.CurrentHealth = combatant.CurrentHealth
	record.model = model
	pcall(AnimalOverhead.Refresh, record)
end

-- Spawn every combatant model, position + face both sides,
-- attach overheads. Any single failure fails the whole spawn
-- (the caller rejects the battle start — never a partial,
-- lopsided fight). Dead player combatants (raid carry-over:
-- Alive == false) are intentionally NOT spawned — no model,
-- no overhead, no failure, no position consumed. They stay
-- listed on battle.playerTeam for UI/summary only.
function ArenaBattleService.SpawnBattleModels(battle: { [string]: any }, base: any): { [string]: any }
	if type(battle) ~= 'table' then
		return { ok = false, error = 'bad-battle' }
	end
	local playerTeam = battle.playerTeam
	local enemyTeam = battle.enemyTeam
	if type(playerTeam) ~= 'table' or #playerTeam < 1 or type(enemyTeam) ~= 'table' or #enemyTeam < 1 then
		return { ok = false, error = 'empty-team' }
	end
	local alivePlayer: { any } = {}
	for _, combatant in ipairs(playerTeam) do
		if type(combatant) == 'table' and combatant.Alive == true then
			alivePlayer[#alivePlayer + 1] = combatant
		else
			-- Dead for the run: guarantee no stale visual refs.
			if type(combatant) == 'table' then
				combatant.Model = nil
				combatant.overheadRecord = nil
			end
		end
	end
	if #alivePlayer < 1 then
		return { ok = false, error = 'all-dead' }
	end
	local positions = ArenaBattleService.ResolveBattlePositions(base, #alivePlayer, #enemyTeam)
	if not positions.ready then
		return { ok = false, error = 'positions-not-ready', missing = positions.missing }
	end
	local root = battleRootFolder()
	if root == nil then
		return { ok = false, error = 'folder-failed' }
	end
	local folder: Folder? = nil
	pcall(function()
		local created = Instance.new('Folder')
		created.Name = ('Battle_%d'):format(battle.sessionId)
		created.Parent = root
		folder = created
	end)
	if folder == nil then
		return { ok = false, error = 'folder-failed' }
	end
	battle.folder = folder
	-- Centroids for facing (flattened: upright models only).
	local function centroid(cframes: { CFrame }): Vector3?
		local sum: Vector3? = nil
		local n = 0
		for _, cf in ipairs(cframes) do
			sum = if sum == nil then cf.Position else (sum :: Vector3) + cf.Position
			n += 1
		end
		if sum == nil or n == 0 then
			return nil
		end
		return (sum :: Vector3) / n
	end
	local playerCentroid = centroid(positions.player)
	local enemyCentroid = centroid(positions.enemy)
	-- Place + face one model, GROUNDED: the model's bottom
	-- face sits flush on the marker's ground-plane point
	-- (`surface`: marker top for parts, the point itself
	-- otherwise). Bottom math is the shared stand helper
	-- (SlotMath.FeetOffsetBelowPrimary: HipHeight-aware,
	-- scale-aware, geometric fallback) — one algorithm for
	-- player and enemy teams, all model heights. X/Z + facing
	-- come from the marker untouched; only Y is corrected.
	-- The returned CFrame becomes the combatant's canonical
	-- HomeCFrame, so attacks always return to grounded.
	local function placeModel(model: Model, at: CFrame, lookTarget: Vector3?, surface: Vector3?): CFrame
		local flat = at.Position
		local look = lookTarget or (at.Position + at.LookVector)
		local faced = CFrame.lookAt(flat, Vector3.new(look.X, flat.Y, look.Z))
		local groundY = if typeof(surface) == 'Vector3' then (surface :: Vector3).Y else flat.Y
		local lift = 0
		pcall(function()
			local feet = SlotMath.FeetOffsetBelowPrimary(model)
			if type(feet) == 'number' and feet == feet and feet < 0 then
				lift = -feet
			end
		end)
		local grounded = CFrame.new(faced.Position.X, groundY + lift, faced.Position.Z) * (faced - faced.Position)
		pcall(function()
			model:PivotTo(grounded)
		end)
		return grounded
	end
	local function spawnOne(
		combatant: { [string]: any },
		index: number,
		at: CFrame,
		surface: Vector3?,
		lookTarget: Vector3?
	): string?
		local model: Model? = nil
		local err: string? = nil
		if combatant.Team == 'Player' and type(combatant.SourceAnimalId) == 'string' then
			model, err = cloneLiveAnimalModel(combatant)
		end
		if model == nil then
			-- Template fallback (persistent model gone): same
			-- look via the canonical template pipeline,
			-- including the combatant's trait.
			model, err = cloneTemplateModel(combatant.DefinitionId, combatant.Trait)
		end
		if model == nil then
			return err or 'model-missing'
		end
		prepCombatModel(model, ('Arena_%s%d'):format(combatant.Team, index))
		model.Parent = folder
		combatant.Model = model
		combatant.HomeCFrame = placeModel(model, at, lookTarget, surface)
		-- Attack body radius, resolved ONCE here (never
		-- GetExtentsSize per frame): drives the per-attack
		-- stop distance so small animals meet close and
		-- giants stop sensibly short.
		local radius = 2.5
		pcall(function()
			local size = (model :: Model):GetExtentsSize()
			local flat = math.max(size.X, size.Z) * 0.5
			if flat == flat and flat > 0 then
				radius = math.clamp(flat, 1.5, 6)
			end
		end)
		combatant.AttackRadius = radius
		-- Overhead record: canonical identity + live combat
		-- HP mirror (same presenter as stands).
		local trait: string? = nil
		local mutations: { string } = {}
		local displayName = combatant.DisplayName
		if combatant.Team == 'Player' and animalServiceRef and animalServiceRef.Get then
			pcall(function()
				local live = animalServiceRef.Get(combatant.SourceAnimalId)
				if type(live) == 'table' then
					if type(live.Trait) == 'string' then
						trait = live.Trait
					end
					if type(live.Mutations) == 'table' then
						for _, id in ipairs(live.Mutations) do
							if type(id) == 'string' then
								mutations[#mutations + 1] = id
							end
						end
					end
					if type(live.displayName) == 'string' and live.displayName ~= '' then
						displayName = live.displayName
					end
				end
			end)
		end
		local record: { [string]: any } = {
			uniqueId = ('Arena_%d_%s'):format(battle.sessionId, combatant.Id),
			definitionId = combatant.DefinitionId,
			displayName = displayName,
			Level = combatant.Level,
			Trait = trait,
			Mutations = mutations,
			model = model,
			CurrentHealth = combatant.CurrentHealth,
			-- Active Arena participation (BOTH teams spawn
			-- here): AnimalOverhead hides Generation/Income
			-- for this transient record while leaving Name,
			-- Rarity, Level, Mutations, Trait, Damage, and
			-- Health untouched. Dies with the battle.
			arenaDeployed = true,
		}
		combatant.overheadRecord = record
		pcall(AnimalOverhead.Refresh, record)
		-- Result-viewport trace root: the EXACT combat instance for
		-- this participant. Keepsake capture (death/stage-end)
		-- clones THIS model; the FullName here must match the
		-- combatModel path in the later [ArenaResultModel] lines.
		if combatant.Team == 'Player' then
			pcall(function()
								Debug.Warn('ArenaResultModel', ('CAPTURE SOURCE session=%s participant=%s combatant=%s model=%s'):format(
						tostring(battle.sessionId),
						tostring(combatant.SourceAnimalId),
						tostring(combatant.Id),
						(model :: Model):GetFullName()
					))
			end)
		end
		return nil
	end
	for i, combatant in ipairs(alivePlayer) do
		local surface = if type(positions.playerSurface) == 'table' then positions.playerSurface[i] else nil
		local fail = spawnOne(combatant, i, positions.player[i], surface, enemyCentroid)
		if fail ~= nil then
			ArenaBattleService.DestroyBattleModels(battle)
			return { ok = false, error = ('player-model-failed:%s:%s'):format(combatant.Id, fail) }
		end
		emitEvent(battle, { Event = 'CombatantSpawned', CombatantId = combatant.Id, Team = 'Player' })
	end
	for i, combatant in ipairs(enemyTeam) do
		local surface = if type(positions.enemySurface) == 'table' then positions.enemySurface[i] else nil
		local fail = spawnOne(combatant, i, positions.enemy[i], surface, playerCentroid)
		if fail ~= nil then
			ArenaBattleService.DestroyBattleModels(battle)
			return { ok = false, error = ('enemy-model-failed:%s:%s'):format(combatant.Id, fail) }
		end
		emitEvent(battle, { Event = 'CombatantSpawned', CombatantId = combatant.Id, Team = 'Enemy' })
	end
	emitEvent(battle, { Event = 'CombatStarted', PlayerCount = #alivePlayer, EnemyCount = #enemyTeam })
	return { ok = true }
end

-- Idempotent teardown: folder destroy removes every combat
-- model (overheads die with their models); refs cleared so
-- a second call is a no-op.
function ArenaBattleService.DestroyBattleModels(battle: { [string]: any })
	if type(battle) ~= 'table' then
		return
	end
	pcall(function()
		local folder = battle.folder
		if typeof(folder) == 'Instance' and (folder :: Instance).Parent ~= nil then
			(folder :: Instance):Destroy()
		end
	end)
	battle.folder = nil
	pcall(function()
		for _, team in ipairs({ battle.playerTeam, battle.enemyTeam }) do
			if type(team) == 'table' then
				for _, c in ipairs(team) do
					if type(c) == 'table' then
						c.Model = nil
						c.overheadRecord = nil
					end
				end
			end
		end
	end)
end

-- Forward declarations for the hit-impact bundle (assigned
-- below PresentAttack; invoked from the attack thread at
-- runtime — same established pattern as settleRaidReward's
-- forward declaration in ArenaService).
local announceAttacker: any = nil
local reactToHit: any = nil

-- --- Full-travel attack presentation (TweenService) ------------------
--
-- One attack at a time, one spawned thread per attack:
--   TRAVEL  — tween home -> stop point near the target (faces it)
--   ATTACK  — one of five short in-place flourishes, then IMPACT:
--             red hit flash + damage popup + overhead HP refresh
--   RETURN  — tween back to the exact canonical home transform
-- Tweens interpolate a parentless per-attack CFrameValue; a
-- single Changed hook applies PivotTo. No per-frame Lua math,
-- no per-animal loops, no Workspace scans. Transform audit:
-- this thread is the ONLY PivotTo writer on battle models
-- (idle tracks drive joints, never the root; death only fades
-- transparency; weight/level systems touch persistent animals
-- only). Every phase aborts cleanly on model loss; the
-- canonical home restores whenever the model still exists.
-- Scale is never touched.
local TRAVEL_DUR = PRESENT.Combat.TravelDuration
local RETURN_DUR = PRESENT.Combat.ReturnDuration

-- Tween one model root from its live pivot to `toCf`. Single
-- connection, destroyed with the tween and driver before
-- return: zero lingering state per phase. Returns false when
-- the model vanished (caller aborts the attack safely).
local function tweenModelTo(model: Model, toCf: CFrame, dur: number): boolean
	if typeof(model) ~= 'Instance' or (model :: Model).Parent == nil then
		return false
	end
	local fromCf: CFrame? = nil
	pcall(function()
		fromCf = (model :: Model):GetPivot()
	end)
	if typeof(fromCf) ~= 'CFrame' then
		return false
	end
	local driver: CFrameValue? = nil
	pcall(function()
		local v = Instance.new('CFrameValue')
		v.Value = fromCf :: CFrame
		driver = v
	end)
	if driver == nil then
		return false
	end
	local finished = false
	pcall(function()
		local conn: RBXScriptConnection? = nil
		conn = (driver :: CFrameValue).Changed:Connect(function(value: CFrame)
			pcall(function()
				if (model :: Model).Parent ~= nil then
					(model :: Model):PivotTo(value)
				end
			end)
		end)
		local tween = TweenService:Create(
			driver :: CFrameValue,
			TweenInfo.new(dur, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut),
			{ Value = toCf }
		)
		tween:Play()
		-- Completed fires on finish AND on cancel: no hangs,
		-- no explicit connection to clean (Wait leaves none).
		tween.Completed:Wait()
		pcall(function()
			tween:Destroy()
		end)
		if conn ~= nil then
			pcall(function()
				(conn :: RBXScriptConnection):Disconnect()
			end)
		end
		finished = true
	end)
	pcall(function()
		(driver :: CFrameValue):Destroy()
	end)
	return finished and (model :: Model).Parent ~= nil
end

-- Hit flash core: one REUSABLE Highlight per model with a
-- generation counter, playing a 3-phase cartoon impact:
--   Phase 1 WHITE FLASH (~FlashDuration): near-opaque white-hot
--     impact, fill + outline both punch.
--   Phase 2 RED PUNCH: configured hit color snaps in.
--   Phase 3 RECOVER: tween to fully transparent over the
--     remainder of Duration, then parked (transparency 1) for
--     reuse — never left tinting the model.
-- Rapid hits bump the generation: the newest hit owns the
-- Highlight, stale tween callbacks exit without touching it, so
-- five fast hits refresh cleanly instead of stacking five
-- Highlights. Parented INTO the model (dies with it — no stuck
-- state). Pure color feedback: CFrames never touched, original
-- part colors/materials never modified. Defaults render the red
-- target-hit flash; the attacker activation cue reuses the same
-- path with its own warm tint/timing.
type FlashEntry = {
	hl: Highlight,
	gen: number,
	tweens: { Tween },
}
local flashEntries: { [Model]: FlashEntry } = {}
local function flashEntryFor(model: Model): FlashEntry?
	local entry = flashEntries[model]
	if entry ~= nil then
		local hl = entry.hl
		if typeof(hl) == 'Instance' and hl.Parent == model then
			return entry
		end
		flashEntries[model] = nil
	end
	return nil
end
local function flashHit(model: Model, fill: Color3?, startTrans: number?, fadeDur: number?)
	local fillColor = fill or PRESENT.HitFlash.Color
	local startTransparency = if type(startTrans) == 'number' then startTrans else PRESENT.HitFlash.StartTransparency
	if startTransparency ~= startTransparency then
		startTransparency = PRESENT.HitFlash.StartTransparency
	end
	startTransparency = math.clamp(startTransparency, 0, 1)
	local duration = if type(fadeDur) == 'number' then fadeDur else PRESENT.HitFlash.Duration
	if duration ~= duration or duration <= 0 then
		duration = PRESENT.HitFlash.Duration
	end
	if duration > PRESENT.HitFlash.MaxDuration then
		duration = PRESENT.HitFlash.MaxDuration
	end
	-- White-flash slice only applies to the default target hit
	-- (custom fill callers like the attacker cue keep their
	-- single-tint behavior with a fast punch-in).
	local isTargetHit = fill == nil
	local flashDur = PRESENT.HitFlash.FlashDuration
	if not isTargetHit then
		flashDur = math.min(0.03, duration * 0.25)
	end
	if flashDur ~= flashDur or flashDur < 0 then
		flashDur = 0
	end
	if flashDur >= duration then
		flashDur = math.max(0, duration - 0.01)
	end
	local recoverDur = math.max(0.01, duration - flashDur)
	pcall(function()
		if typeof(model) ~= 'Instance' or (model :: Model).Parent == nil then
			return
		end
		local entry = flashEntryFor(model)
		local hl: Highlight
		if entry ~= nil then
			entry.gen += 1
			hl = entry.hl
			for _, tw in ipairs(entry.tweens) do
				pcall(function()
					(tw :: Tween):Cancel()
				end)
				pcall(function()
					(tw :: Tween):Destroy()
				end)
			end
			table.clear(entry.tweens)
		else
			hl = Instance.new('Highlight')
			hl.Name = 'ArenaHitFlash'
			hl.Parent = model
			entry = { hl = hl, gen = 1, tweens = {} }
			flashEntries[model] = entry
		end
		local myGen = entry.gen
		local flashColor = if isTargetHit then PRESENT.HitFlash.FlashColor else fillColor
		local flashTrans = if isTargetHit then PRESENT.HitFlash.FlashTransparency else startTransparency
		local outlinePeak = if isTargetHit
			then PRESENT.HitFlash.OutlinePeakTransparency
			else math.clamp(startTransparency, 0, 1)
		-- Phase 1: impact flash, applied INSTANTLY (same tick as
		-- damage commit / VFX packet — zero stagger). Phases 2+3
		-- run in a spawned thread: flashHit NEVER yields the
		-- caller, so authoritative hit timing is untouched.
		hl.FillColor = flashColor
		hl.OutlineColor = flashColor
		hl.FillTransparency = math.clamp(flashTrans, 0, 1)
		hl.OutlineTransparency = math.clamp(outlinePeak, 0, 1)
		local liveEntry = entry
		task.spawn(function()
			pcall(function()
				-- Phase 2: red punch snaps in over the flash slice.
				if isTargetHit and flashDur > 0 then
					local punchIn = TweenService:Create(
						hl,
						TweenInfo.new(flashDur, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
						{
							FillColor = fillColor,
							OutlineColor = fillColor,
							FillTransparency = startTransparency,
							OutlineTransparency = math.clamp(startTransparency, 0, 1),
						}
					)
					liveEntry.tweens[#liveEntry.tweens + 1] = punchIn
					punchIn:Play()
					punchIn.Completed:Wait()
					if liveEntry.gen ~= myGen or hl.Parent ~= model then
						return
					end
				elseif not isTargetHit then
					hl.FillColor = fillColor
					hl.OutlineColor = fillColor
				end
				-- Phase 3: recover to invisible, then park for reuse.
				local fade = TweenService:Create(hl, TweenInfo.new(recoverDur), {
					FillTransparency = 1,
					OutlineTransparency = 1,
				})
				liveEntry.tweens[#liveEntry.tweens + 1] = fade
				fade:Play()
				local genAtFade = myGen
				pcall(function()
					fade.Completed:Wait()
				end)
				pcall(function()
					fade:Destroy()
				end)
				-- Stale callback (a newer hit owns the Highlight):
				-- touch nothing.
				if liveEntry.gen ~= genAtFade then
					return
				end
				-- Park invisible for reuse; drop the table entry only
				-- if the model is gone (its Highlight dies with it).
				pcall(function()
					if hl.Parent == model then
						hl.FillTransparency = 1
						hl.OutlineTransparency = 1
					else
						flashEntries[model] = nil
					end
				end)
			end)
		end)
	end)
end

-- Five short in-place flourishes run AT the stop point (the
-- travel/return tweens own the journey). Each derives purely
-- from its `origin` argument — never from the live pivot —
-- and ends near the origin; the return tween guarantees the
-- exact home landing regardless.
-- 1. LUNGE: lean-back anticipation, forward strike, settle.
local function animLunge(model: Model, origin: CFrame, toward: Vector3, _right: Vector3): boolean
	if not tweenModelTo(model, origin - toward * 1.0, 0.08) then
		return false
	end
	if not tweenModelTo(model, origin + toward * 2.0, 0.08) then
		return false
	end
	return tweenModelTo(model, origin, 0.12)
end

-- 2. HOP + SLAM: vertical hop with pitch, slam down forward,
-- settle.
local function animHopSlam(model: Model, origin: CFrame, toward: Vector3, _right: Vector3): boolean
	if not tweenModelTo(model, (origin + Vector3.yAxis * 2.5) * CFrame.Angles(0.45, 0, 0), 0.12) then
		return false
	end
	if not tweenModelTo(model, origin + toward * 1.0, 0.1) then
		return false
	end
	return tweenModelTo(model, origin, 0.1)
end

-- 3. SPIN ATTACK: three chained 120-degree yaw steps with a
-- slight forward pulse, settle. (Chained tweens keep the spin
-- smooth without per-frame math.)
local function animSpin(model: Model, origin: CFrame, toward: Vector3, _right: Vector3): boolean
	local pulse = toward * 0.5
	for i = 1, 3 do
		if not tweenModelTo(model, (origin + pulse * (i / 3)) * CFrame.Angles(0, (i / 3) * math.pi * 2, 0), 0.08) then
			return false
		end
	end
	return tweenModelTo(model, origin, 0.08)
end

-- 4. SIDE SWING: strafe right with roll, rapid left/right
-- sways, strike pose, settle.
local function animSideSwing(model: Model, origin: CFrame, _toward: Vector3, right: Vector3): boolean
	if not tweenModelTo(model, (origin + right * 1.5) * CFrame.Angles(0, 0, 0.26), 0.08) then
		return false
	end
	if not tweenModelTo(model, (origin - right * 1.5) * CFrame.Angles(0, 0, -0.26), 0.08) then
		return false
	end
	if not tweenModelTo(model, (origin + right * 1.5) * CFrame.Angles(0, 0, 0.26), 0.06) then
		return false
	end
	return tweenModelTo(model, origin, 0.08)
end

-- 5. BOUNCE / CHARGE: crouch compress, spring up-forward,
-- settle.
local function animBounceCharge(model: Model, origin: CFrame, toward: Vector3, _right: Vector3): boolean
	if not tweenModelTo(model, origin - Vector3.yAxis * 0.8, 0.1) then
		return false
	end
	if not tweenModelTo(model, origin + Vector3.yAxis * 2 + toward * 1.5, 0.1) then
		return false
	end
	return tweenModelTo(model, origin, 0.12)
end

type AttackAnimSpec = {
	name: string,
	dur: number,
	impactOffset: number,
	run: (Model, CFrame, Vector3, Vector3) -> boolean,
}

local ATTACK_ANIMS: { AttackAnimSpec } = {
	{
		name = 'Lunge',
		dur = PRESENT.AttackAnims[1].Duration,
		impactOffset = PRESENT.AttackAnims[1].ImpactOffset,
		run = animLunge,
	},
	{
		name = 'HopSlam',
		dur = PRESENT.AttackAnims[2].Duration,
		impactOffset = PRESENT.AttackAnims[2].ImpactOffset,
		run = animHopSlam,
	},
	{
		name = 'Spin',
		dur = PRESENT.AttackAnims[3].Duration,
		impactOffset = PRESENT.AttackAnims[3].ImpactOffset,
		run = animSpin,
	},
	{
		name = 'SideSwing',
		dur = PRESENT.AttackAnims[4].Duration,
		impactOffset = PRESENT.AttackAnims[4].ImpactOffset,
		run = animSideSwing,
	},
	{
		name = 'BounceCharge',
		dur = PRESENT.AttackAnims[5].Duration,
		impactOffset = PRESENT.AttackAnims[5].ImpactOffset,
		run = animBounceCharge,
	},
}

-- Attack presentation: ONE spawned thread per attack (never
-- yields the tick): activation cue, smooth travel to the
-- target, one flourish, HIT_CONTACT, smooth return. Purely
-- server-side motion + flash + reaction; the client bundle
-- (VFX/sound/number/camera) fires from the SAME contact
-- moment via one ArenaHit packet. Sim state is already
-- committed — nothing here re-decides anything. Returns the
-- visual impact delay in seconds (0 when nothing was
-- presented) so staged server effects (death fade) land on
-- the hit.
function ArenaBattleService.PresentAttack(battle: { [string]: any }, attack: { [string]: any }): number
	if type(attack) ~= 'table' then
		return 0
	end
	local attacker = findCombatant(battle, attack.attackerId)
	local target = findCombatant(battle, attack.targetId)
	if attacker == nil or target == nil then
		return 0
	end
	local model = liveModel(attacker)
	local targetModel = liveModel(target)
	if model == nil or targetModel == nil then
		return 0
	end
	local idx = tonumber(attack.attackAnimation) or 1
	if idx ~= idx or idx < 1 or idx > ATTACK_ANIMATION_COUNT then
		idx = 1
	end
	idx = math.floor(idx)
	local spec = ATTACK_ANIMS[idx]
	-- Canonical rest transform FIRST (spawn-time HomeCFrame;
	-- live pivot fallback for legacy/test battles).
	local home: CFrame? = attacker.HomeCFrame
	if typeof(home) ~= 'CFrame' then
		pcall(function()
			home = (model :: Model):GetPivot()
		end)
	end
	if typeof(home) ~= 'CFrame' then
		return 0
	end
	local resolvedHome = home :: CFrame
	local foePivot: CFrame? = target.HomeCFrame
	if typeof(foePivot) ~= 'CFrame' then
		pcall(function()
			foePivot = (targetModel :: Model):GetPivot()
		end)
	end
	if typeof(foePivot) ~= 'CFrame' then
		return 0
	end
	local foePos = (foePivot :: CFrame).Position
	-- Horizontal facing (never pitch the whole animal up/down).
	local toward = resolvedHome.LookVector
	local flat = foePos - resolvedHome.Position
	local gap = Vector3.new(flat.X, 0, flat.Z).Magnitude
	if gap > 0.01 then
		toward = Vector3.new(flat.X, 0, flat.Z).Unit
	end
	-- Attack stop point from CACHED body radii (resolved once
	-- at spawn — never GetExtentsSize per frame): the attacker
	-- closes to attacker + target radius + a small gap, so
	-- small animals meet close and giants stop sensibly short.
	-- Clamped so degenerate sizes can't produce nonsense.
	local function cleanRadius(value: any): number
		local n = tonumber(value) or 2.5
		if n ~= n or n <= 0 then
			n = 2.5
		end
		return math.clamp(n, 1.5, 6)
	end
	local attackDist = math.clamp(cleanRadius(attacker.AttackRadius) + cleanRadius(target.AttackRadius) + 1.5, 3, 14)
	local stopPos = foePos - toward * math.min(attackDist, math.max(gap - 0.5, 0))
	local travelSkipped = (stopPos - resolvedHome.Position).Magnitude < 1
	-- Face the target, keep our own height (horizontal lookAt).
	local stopCf = CFrame.lookAt(stopPos, Vector3.new(foePos.X, stopPos.Y, foePos.Z))
	local resolvedToward = toward
	local resolvedRight = stopCf.RightVector
	-- Visual hit-stop: a tiny emphasis beat at contact. The
	-- scheduler is untouched (turns still gate on
	-- TURN_INTERVAL, which comfortably contains it).
	-- Canonical: ArenaPresentationConfig.Combat.HitStop.
	local HIT_STOP = PRESENT.Combat.HitStop
	local impactDelay = (if travelSkipped then 0 else TRAVEL_DUR) + spec.impactOffset
	local contact = computeContactPoint(attacker, target)
	local soundIdx = math.clamp(math.floor(tonumber(attack.soundIndex) or 1), 1, PRESENT.Sfx.SlotCount)
	local damage = tonumber(attack.damage) or 0
	if damage ~= damage or damage < 0 then
		damage = 0
	end
	local seq = tonumber(attack.attackSequence) or 0
	task.spawn(function()
		pcall(function()
			-- Attacker activation cue: subtle warm rim so
			-- spectators see WHO attacks before it moves.
			announceAttacker(model)
			if not travelSkipped then
				if not tweenModelTo(model, stopCf, TRAVEL_DUR) then
					return
				end
			end
			spec.run(model, stopCf, resolvedToward, resolvedRight)
			task.wait(HIT_STOP)
			-- HIT_CONTACT: the single authoritative impact.
			-- Server presents motion-bound feedback (flash,
			-- reaction, HP refresh, staged death); ONE packet
			-- fans out to clients for VFX/sound/number/camera
			-- at this exact moment. Damage was committed at
			-- turn start — nothing here re-decides anything.
			-- The target reaction runs in its own short
			-- thread (other model, no fight).
			local liveTarget = liveModel(target)
			if liveTarget ~= nil then
				flashHit(liveTarget)
				local targetHome: CFrame? = target.HomeCFrame
				if typeof(targetHome) ~= 'CFrame' then
					targetHome = nil
					pcall(function()
						targetHome = (liveTarget :: Model):GetPivot()
					end)
				end
				if typeof(targetHome) == 'CFrame' then
					local reactHome = targetHome :: CFrame
					local away = resolvedToward
					task.spawn(function()
						pcall(function()
							reactToHit(liveTarget, reactHome, away)
						end)
					end)
				end
			end
			refreshCombatantOverhead(target)
			emitHitEvent(battle, {
				Event = 'ArenaHit',
				AttackerId = attacker.Id,
				AttackerTeam = attacker.Team,
				TargetId = target.Id,
				TargetTeam = target.Team,
				Damage = damage,
				ImpactPosition = contact,
				AttackIndex = idx,
				SoundIndex = soundIdx,
				AttackSequence = seq,
			})
			if not tweenModelTo(model, resolvedHome, RETURN_DUR) then
				return
			end
			-- Canonical restore: exact home landing (drift-free
			-- by construction — everything derived from it).
			pcall(function()
				if (model :: Model).Parent ~= nil then
					(model :: Model):PivotTo(resolvedHome)
				end
			end)
		end)
	end)
	return impactDelay + HIT_STOP
end

-- --- Arena server-side impact feedback ------------------------------
--
-- The attack thread presents motion-bound feedback ONLY
-- (activation cue, target flash, reaction, HP refresh, staged
-- death). VFX/sound/damage numbers present CLIENT-side from
-- the single ArenaHit packet (one trigger, zero replication
-- skew) — the server never spawns them, so duplicates are
-- impossible by construction.
-- Attacker activation cue: an extremely subtle warm rim at
-- attack start (~0.12s) so spectators see WHO is attacking
-- before it moves. Never stacks (one thread per attack),
-- never lingers (self-destroying Highlight).
announceAttacker = function(model: Model)
	flashHit(model, PRESENT.AttackerCue.Color, PRESENT.AttackerCue.StartTransparency, PRESENT.AttackerCue.Duration)
end

-- Target hit reaction: tiny upward/backward jolt + settle
-- back to the EXACT canonical home (positional only — no
-- scale systems touched, no drift possible). Runs in its own
-- short thread in parallel with the attacker's recoil (other
-- model, no transform fight). Abort-safe on model loss.
reactToHit = function(targetModel: Model, targetHome: CFrame, awayDir: Vector3)
	pcall(function()
		if typeof(targetModel) ~= 'Instance' or (targetModel :: Model).Parent == nil then
			return
		end
		if typeof(targetHome) ~= 'CFrame' then
			return
		end
		local away = Vector3.zero
		if typeof(awayDir) == 'Vector3' then
			away = awayDir
		end
		local bumped = (targetHome :: CFrame)
			+ Vector3.new(0, PRESENT.HitJolt.LiftStuds, 0)
			+ away * PRESENT.HitJolt.ShoveStuds
		if not tweenModelTo(targetModel, bumped, PRESENT.HitJolt.OutDuration) then
			return
		end
		if not tweenModelTo(targetModel, targetHome :: CFrame, PRESENT.HitJolt.BackDuration) then
			return
		end
		pcall(function()
			if (targetModel :: Model).Parent ~= nil then
				(targetModel :: Model):PivotTo(targetHome :: CFrame)
			end
		end)
	end)
end

-- NOTE: server-side damage popups/VFX/sound were removed:
-- impact presentation (number/VFX/sound/camera) now runs
-- CLIENT-side from the single ArenaHit packet, so the bundle
-- lands simultaneously with zero replication skew. See
-- StarterPlayerScripts/ArenaHitPresentation. The server keeps
-- motion, flash, reaction, and death only.

-- --- Result keepsakes (actual combat models for viewports) -----
--
-- The ArenaResult viewport must show the ACTUAL combat animal
-- (Workspace.ArenaBattles.Battle_<N>.Arena_Player<M>), not a
-- reconstructed template. But death fades destroy dead models
-- and advance/terminal cleanup destroys the rest — by raid end
-- a wiped team has NO models left. So each player combatant's
-- model is cloned exactly once, synchronously, while it is still
-- alive-and-parented: at death (CaptureKeepsake, before the fade)
-- or at stage end (CaptureLiveKeepsakes, before advance/cleanup).
-- Keepsakes park OUTSIDE the battle folder
-- (ReplicatedStorage.ArenaResultModels/Session_<sessionId>) so
-- battle teardown never touches them AND every client can see
-- them (Workspace streaming is never involved); ArenaService
-- merges them into the raid session keyed by persistent
-- SourceAnimalId (stable across stages, unique across
-- same-species duplicates). Enemy combatants are never kept.
-- Lifecycle: Debris backup (180s) at capture + explicit
-- session-folder destroy after the result is sent
-- (terminateRaid), so nothing accumulates.
local KEEPSAKE_ROOT_NAME = 'ArenaResultModels'
local KEEPSAKE_TTL_S = 180

local function keepsakeRoot(): Folder?
	local root: Folder? = nil
	pcall(function()
		root = ReplicatedStorage:FindFirstChild(KEEPSAKE_ROOT_NAME)
		if root == nil then
			local created = Instance.new('Folder')
			created.Name = KEEPSAKE_ROOT_NAME
			created.Parent = ReplicatedStorage
			root = created
		end
	end)
	return root
end

-- Clone one player combatant's live combat model into the
-- keepsake store. Synchronous, idempotent per combatant (first
-- capture wins — death-time state beats any later state). No-op
-- for enemies, missing models, missing ids, or headless battles
-- (no combat models). Never touches the live model.
function ArenaBattleService.CaptureKeepsake(battle: { [string]: any }, combatant: { [string]: any }?, model: Model?)
	if type(battle) ~= 'table' or type(combatant) ~= 'table' then
		return
	end
	if combatant.Team ~= 'Player' or type(combatant.SourceAnimalId) ~= 'string' then
		return
	end
	if type(battle.keepsakeModels) ~= 'table' then
		battle.keepsakeModels = {}
	end
	if battle.keepsakeModels[combatant.Id] ~= nil then
		return
	end
	local live = model or liveModel(combatant)
	if typeof(live) ~= 'Instance' or (live :: Model).Parent == nil then
		return
	end
	pcall(function()
		local root = keepsakeRoot()
		if root == nil then
			return
		end
		local folder: Folder? = nil
		local folderName = ('Session_%s'):format(tostring(battle.sessionId))
		for _, child in ipairs(root:GetChildren()) do
			if child.Name == folderName and child:IsA('Folder') then
				folder = child
				break
			end
		end
		if folder == nil then
			local created = Instance.new('Folder')
			created.Name = folderName
			created.Parent = root
			folder = created
		end
		local clone = (live :: Model):Clone()
		clone.Name = ('Result_%s'):format(tostring(combatant.SourceAnimalId))
		clone.Parent = folder
		battle.keepsakeModels[combatant.Id] = clone
		-- Backup expiry so abandoned raids (leave/crash between
		-- capture and result) can never accumulate clones.
		Debris:AddItem(clone, KEEPSAKE_TTL_S)
				Debug.Warn('ArenaResultModel', ('CLONED session=%s participant=%s combatant=%s source=%s clone=%s class=%s'):format(
				tostring(battle.sessionId),
				tostring(combatant.SourceAnimalId),
				tostring(combatant.Id),
				(live :: Model):GetFullName(),
				clone:GetFullName(),
				clone.ClassName
			))
	end)
end

-- Capture keepsakes for every player combatant that still has a
-- live model (the survivors at stage end). Dead combatants were
-- already captured at death; the idempotency guard skips them.
function ArenaBattleService.CaptureLiveKeepsakes(battle: { [string]: any })
	if type(battle) ~= 'table' or type(battle.playerTeam) ~= 'table' then
		return
	end
	for _, c in ipairs(battle.playerTeam) do
		if type(c) == 'table' then
			ArenaBattleService.CaptureKeepsake(battle, c, liveModel(c))
		end
	end
end

-- Drain this battle's keepsakes as {[SourceAnimalId] = Model}
-- for the raid session to accumulate (stable across stages).
-- Battle entries are consumed (cleared) so a repeated collect
-- can never duplicate them.
function ArenaBattleService.TakeKeepsakes(battle: { [string]: any }): { [string]: Model }
	local out: { [string]: Model } = {}
	if type(battle) ~= 'table' then
		return out
	end
	local function combatantById(id: string): { [string]: any }?
		for _, team in ipairs({ battle.playerTeam, battle.enemyTeam }) do
			if type(team) == 'table' then
				for _, c in ipairs(team) do
					if type(c) == 'table' and c.Id == id then
						return c
					end
				end
			end
		end
		return nil
	end
	if type(battle.keepsakeModels) == 'table' then
		for id, clone in pairs(battle.keepsakeModels) do
			local owner = if type(id) == 'string' then combatantById(id) else nil
			if
				type(owner) == 'table'
				and owner.Team == 'Player'
				and type(owner.SourceAnimalId) == 'string'
				and typeof(clone) == 'Instance'
				and (clone :: Instance).Parent ~= nil
			then
				out[owner.SourceAnimalId] = clone :: Model
			end
		end
		table.clear(battle.keepsakeModels)
	end
	return out
end

-- Destroy one session's keepsake folder (post-result cleanup).
-- Cycles through Debris for stragglers is unnecessary: capture
-- already armed a Debris backup per clone.
function ArenaBattleService.ClearSessionKeepsakes(sessionId: number)
	pcall(function()
		local root = ReplicatedStorage:FindFirstChild(KEEPSAKE_ROOT_NAME)
		if root == nil then
			return
		end
		local folder = root:FindFirstChild(('Session_%s'):format(tostring(sessionId)))
		if folder ~= nil then
			folder:Destroy()
		end
	end)
end

-- Death presentation: fade out, unregister + destroy the
-- overhead, then destroy the model. Bounded, spawned,
-- guarded — never blocks the tick, never leaks rainbow
-- registrations. `delaySec` stages the visual fade on the
-- attack's impact moment (the killing blow's popup/flash
-- land first); combatant refs clear synchronously regardless
-- so sim state never lags the visual.
--
-- KEEPSAKE (ArenaResult viewports): the dying combatant's model
-- is cloned synchronously here — BEFORE the fade thread below
-- can transparentize/destroy it — and parked outside the battle
-- folder. Player team only. Without this, a wiped team's models
-- are all gone by raid end and the result has nothing real to
-- show. The clone is pristine (client strips its own copy).
function ArenaBattleService.PresentDeath(battle: { [string]: any }, combatantId: string, delaySec: number?)
	local combatant = findCombatant(battle, combatantId)
	if combatant == nil then
		return
	end
	-- Death trace: WHO died, in WHICH session. Death removes the
	-- combatant from active presentation only (Model/overhead
	-- refs clear below) — the persistent result roster lives in
	-- ArenaService.session.team and is never touched here.
	if type(combatant) == 'table' then
		local aliveLeft = 0
		for _, team in ipairs({ battle.playerTeam, battle.enemyTeam }) do
			if type(team) == 'table' then
				for _, c in ipairs(team) do
					if type(c) == 'table' and c.Alive == true and c.Id ~= combatantId then
						aliveLeft += 1
					end
				end
			end
		end
				Debug.Warn('ArenaDeath', ('session=%s uniqueId=%s name=%s team=%s aliveRemaining=%d'):format(
				tostring(battle.sessionId),
				tostring(combatant.SourceAnimalId),
				tostring(combatant.DisplayName),
				tostring(combatant.Team),
				aliveLeft
			))
	end
	local model = liveModel(combatant)
	local record = combatant.overheadRecord
	ArenaBattleService.CaptureKeepsake(battle, combatant, model)
	combatant.Model = nil
	combatant.overheadRecord = nil
	if model == nil then
		return
	end
	local delay = tonumber(delaySec) or 0
	if delay ~= delay or delay < 0 then
		delay = 0
	end
	if delay > PRESENT.DeathFade.MaxPreDelay then
		delay = PRESENT.DeathFade.MaxPreDelay
	end
	task.spawn(function()
		pcall(function()
			if delay > 0 then
				task.wait(delay)
			end
			for step = 1, PRESENT.DeathFade.Steps do
				if model.Parent == nil then
					return
				end
				for _, desc in ipairs(model:GetDescendants()) do
					if desc:IsA('BasePart') then
						(desc :: BasePart).Transparency = step / PRESENT.DeathFade.Steps
					end
				end
				task.wait(PRESENT.DeathFade.StepWait)
			end
		end)
		if type(record) == 'table' then
			pcall(AnimalOverhead.RemoveForAnimal, record)
		end
		pcall(function()
			model:Destroy()
		end)
		pcall(function()
			Debris:AddItem(model, 0)
		end)
	end)
end

function ArenaBattleService._TestReset()
	table.clear(battles)
	table.clear(flashEntries)
	pcall(function()
		local root = ReplicatedStorage:FindFirstChild(KEEPSAKE_ROOT_NAME)
		if root ~= nil then
			root:Destroy()
		end
	end)
	stopScheduler()
	validatorRef = nil
	onBattleEndRef = nil
	onBattleCancelRef = nil
	eventSinkRef = nil
	animalServiceRef = nil
	combatantSeq = 0
end

return table.freeze(ArenaBattleService)
