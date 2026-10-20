--!strict
--!native
--[[
	Tutorial.TutorialService
	=========================
	Server-authoritative first-time-player onboarding as a thin
	guide layer over the real game systems. The service NEVER
	implements gameplay (no purchasing, hatching, grabbing,
	arena, upgrade, or lock logic) — it observes committed
	actions via TutorialSignals and advances one current step.

	State machine (exactly one active step per player):
	  BuyEgg -> WaitForEgg -> HatchEgg -> PickUpAnimal ->
	  PlaceAnimal -> StartArena -> ArenaStarted -> ArenaEnded ->
	  UpgradeAnimal -> LockBase -> Completed

	Identity chain (never a random nearby object):
	  the ACTUAL purchased egg id -> the ACTUAL hatched animal
	  id -> that animal placed in an arena slot -> that
	  player's arena session -> that animal upgraded -> that
	  player's base locked.

	Only Continue is a client intent (TutorialAction); every
	other transition fires on trusted server events. Continue
	is gated: accepted only while the server itself is in
	ArenaEnded for that player.

	Persistence: profile.Data.Tutorial = { Completed, Step,
	EggId, AnimalId } (PlayerService template + reconcile +
	wipe conventions). Rejoin resumes from persisted state
	validated against live registries; tracked Instances are
	rebuilt from ids, never trusted blindly.

	Clients render from TutorialState snapshots + a per-player
	CollectionService tag ('TutorialTarget_<userId>') the server
	moves between that player's tracked models.
]]

local Players = game:GetService('Players')
local CollectionService = game:GetService('CollectionService')
local RunService = game:GetService('RunService')
local ReplicatedStorage = game:GetService('ReplicatedStorage')

local TutorialSignals = require(script.Parent.TutorialSignals)
local SlotType = require(ReplicatedStorage.Types.SlotType)
local Remotes = require(ReplicatedStorage.Utility.Remotes)
local Debug = require(ReplicatedStorage.Utility.Debug)
local EggConfig = require(ReplicatedStorage.Config.Creatures.Eggs)
local RarityDefs = require(ReplicatedStorage.Config.Creatures.Rarity)
-- Funnel analytics (leaf module — never gameplay-critical).
local FunnelService = require(script.Parent.Parent.FunnelService)
-- Player monitoring (Discord embeds + registry; leaf module,
-- never gameplay-critical).
local PlayerLogger = require(script.Parent.Parent.PlayerLogger.PlayerLogger)

local TutorialService = {}

-- --- Steps ---------------------------------------------------------

TutorialService.Step = {
	BuyEgg = 'BuyEgg',
	WaitForEgg = 'WaitForEgg',
	HatchEgg = 'HatchEgg',
	PickUpAnimal = 'PickUpAnimal',
	PlaceAnimal = 'PlaceAnimal',
	StartArena = 'StartArena',
	ArenaStarted = 'ArenaStarted',
	ArenaEnded = 'ArenaEnded',
	UpgradeAnimal = 'UpgradeAnimal',
	LockBase = 'LockBase',
	Completed = 'Completed',
}

TutorialService.TAG = 'TutorialTarget'

-- Per-player tag name: CollectionService tags are GLOBAL, so a
-- shared 'TutorialTarget' tag would expose every player's
-- tracked egg/animal to every other player's client (each
-- client would beam at whoever was tagged last). Scoping the
-- tag by user id keeps each client's highlight on their own
-- objects only. TAG above remains the shared prefix.
function TutorialService.TagFor(userId: number): string
	return TutorialService.TAG .. '_' .. tostring(userId)
end

-- Tutorial beam asset consumed by the client controller. Kept
-- as a function (not a field) so the id is pinned in one
-- place and cheap to assert in specs.
function TutorialService.BeamAssetId(): number
	return 14403995847
end

-- Deterministic starter egg rarity for EVERY new tutorial
-- player: the canonical lowest egg from EggConfig (cheapest
-- price — Common today), never hardcoded here. Per-player by
-- construction: each player's BuyEgg target is this rarity,
-- and after THEY buy, their own actual EggId is what the
-- state machine tracks (never another player's egg, never a
-- server-global egg variable).
function TutorialService.StarterEggRarity(): string
	local found: string? = nil
	pcall(function()
		found = EggConfig.GetStarterRarity()
	end)
	if type(found) == 'string' and found ~= '' then
		return found
	end
	-- Unreachable unless EggConfig itself fails to load: same
	-- canonical order fallback the config helper uses (still
	-- no hardcoded rarity name here).
	local orderFallback: string? = nil
	pcall(function()
		orderFallback = RarityDefs.Order[1]
	end)
	if type(orderFallback) == 'string' and orderFallback ~= '' then
		return orderFallback
	end
	return 'Common'
end

-- Replicate the beam template for clients. Accepts ANY
-- successfully-loaded instance type (Model, MeshPart, Beam,
-- Decal, ...) — the client inspects it and adapts. Load
-- failures print the EXACT Roblox error (never swallowed) so
-- a private/deleted/wrong-type asset is diagnosable in Studio
-- output. Never throws, never blocks boot (spawned thread).
local function _publishBeamTemplate()
	pcall(function()
		if ReplicatedStorage:FindFirstChild('TutorialBeamTemplate') ~= nil then
			return
		end
		local insertService: any = nil
		pcall(function()
			insertService = game:GetService('InsertService')
		end)
		if insertService == nil then
			Debug.Log('TS', 'beam asset: InsertService unavailable; clients use fallback beam')
			return
		end
		local loaded: Instance? = nil
		local loadErr: string? = nil
		pcall(function()
			local ok, result = pcall(function()
				return (insertService :: any):LoadAsset(TutorialService.BeamAssetId())
			end)
			if ok then
				loaded = result
			else
				loadErr = tostring(result)
			end
		end)
		if loaded == nil or typeof(loaded) ~= 'Instance' then
			Debug.Log('TS', 
					tostring(loadErr)
				)
			return
		end
		local template = loaded :: Instance
		template.Name = 'TutorialBeamTemplate'
		template.Parent = ReplicatedStorage
		local census: { [string]: number } = { [template.ClassName] = 1 }
		pcall(function()
			for _, desc in ipairs(template:GetDescendants()) do
				census[desc.ClassName] = (census[desc.ClassName] or 0) + 1
			end
		end)
		local parts: { string } = {}
		for className, count in pairs(census) do
			parts[#parts + 1] = className .. 'x' .. tostring(count)
		end
		table.sort(parts)
				Debug.Log('TS', ('beam template published root=%s children={%s}'):format(template.ClassName, table.concat(parts, ', ')))
	end)
end

-- Arena-slot test from the id alone (normal slot indices are
-- <= 99; arena stands use ArenaSlotIndexBase + k). There is no
-- SlotType.IsArenaSlot helper, so the rule lives here, next
-- to its only consumer.
local function _isArenaSlotId(slotId: any): boolean
	if type(slotId) ~= 'string' then
		return false
	end
	local index = tonumber(string.match(slotId, ':(%d+)$'))
	return index ~= nil and index >= SlotType.ArenaSlotIndexBase
end

-- --- Lazy service refs (no load-time cycles) -------------------------

local _playerService: any = nil
local _spawnService: any = nil
local _animalService: any = nil
local _slotService: any = nil
local _baseService: any = nil

local function _services(): boolean
	if
		_playerService ~= nil
		and _spawnService ~= nil
		and _animalService ~= nil
		and _slotService ~= nil
		and _baseService ~= nil
	then
		return true
	end
	local ok = pcall(function()
		local sss = game:GetService('ServerScriptService')
		if _playerService == nil then
			_playerService = require(sss.PlayerService)
		end
		if _spawnService == nil then
			_spawnService = require(sss.Egg.SpawnService)
		end
		if _animalService == nil then
			_animalService = require(sss.AnimalService)
		end
		if _slotService == nil then
			_slotService = require(sss.Base.SlotService)
		end
		if _baseService == nil then
			_baseService = require(sss.BaseService)
		end
	end)
	return ok
		and _playerService ~= nil
		and _spawnService ~= nil
		and _animalService ~= nil
		and _slotService ~= nil
		and _baseService ~= nil
end

-- --- Runtime -----------------------------------------------------------

-- _active[userId] = { Step: string, EggId: string?, AnimalId: string? }
local _active: { [number]: any } = {}
local _started = false
local _tickConn: RBXScriptConnection? = nil
local _tickAccum = 0

local function _defaultPersisted(): any
	return { Completed = false, Step = TutorialService.Step.BuyEgg, EggId = nil, AnimalId = nil }
end

-- --- Pure transition core (spec-testable, no services) ------------------

-- NextStep(state, event) -> new state table or nil (no
-- transition). `event` carries Name + optional EggId /
-- AnimalId / SlotId / BaseId. Tracked ids must match; arena
-- placement additionally requires an arena slot id.
--
-- THE centralized transition validator — every progression
-- path (bus events, intents) flows through this function, so
-- the table below is exhaustive. Anything not listed here
-- returns nil and changes nothing; in particular there is NO
-- transition back to BuyEgg from any later step (a hatch can
-- never reset the chain — EggHatched from HatchEgg yields
-- PickUpAnimal with the result animal id).
--
--   BuyEgg + EggPurchased(any egg) ......... WaitForEgg(track it)
--   WaitForEgg + EggPlaced(tracked) ........ HatchEgg
--   HatchEgg + EggHatched(tracked -> id) ... PickUpAnimal(track it)
--   PickUpAnimal + AnimalPickedUp(tracked) . PlaceAnimal
--   PlaceAnimal + AnimalPlaced(tracked, arena slot) . StartArena
--   StartArena + ArenaStarted .............. ArenaStarted
--   ArenaStarted + ArenaEnded .............. ArenaEnded
--   ArenaStarted + ArenaCancelled .......... StartArena (recover)
--   ArenaEnded + ContinueConfirmed ......... UpgradeAnimal
--   UpgradeAnimal + AnimalUpgraded(tracked)  LockBase
--   LockBase + BaseLocked(own base) ........ Completed
--   Completed + anything ................... nil (terminal)
function TutorialService.NextStep(state: any, event: any): any?
	local result: any? = nil
	pcall(function()
		if type(state) ~= 'table' or type(event) ~= 'table' then
			return
		end
		local step = state.Step
		local name = event.Name
		if step == TutorialService.Step.Completed then
			return
		end
		if name == 'EggPurchased' then
			if step == TutorialService.Step.BuyEgg and type(event.EggId) == 'string' then
				result = { Step = TutorialService.Step.WaitForEgg, EggId = event.EggId, AnimalId = nil }
			end
		elseif name == 'EggPlaced' then
			if step == TutorialService.Step.WaitForEgg and event.EggId == state.EggId then
				result = { Step = TutorialService.Step.HatchEgg, EggId = state.EggId, AnimalId = nil }
			end
		elseif name == 'EggHatched' then
			if
				step == TutorialService.Step.HatchEgg
				and event.EggId == state.EggId
				and type(event.AnimalId) == 'string'
			then
				result = { Step = TutorialService.Step.PickUpAnimal, EggId = nil, AnimalId = event.AnimalId }
			end
		elseif name == 'AnimalPickedUp' then
			if step == TutorialService.Step.PickUpAnimal and event.AnimalId == state.AnimalId then
				result = { Step = TutorialService.Step.PlaceAnimal, EggId = nil, AnimalId = state.AnimalId }
			end
		elseif name == 'AnimalPlaced' then
			if
				step == TutorialService.Step.PlaceAnimal
				and event.AnimalId == state.AnimalId
				and _isArenaSlotId(event.SlotId)
			then
				result = { Step = TutorialService.Step.StartArena, EggId = nil, AnimalId = state.AnimalId }
			end
		elseif name == 'ArenaStarted' then
			if step == TutorialService.Step.StartArena then
				result = { Step = TutorialService.Step.ArenaStarted, EggId = nil, AnimalId = state.AnimalId }
			end
		elseif name == 'ArenaEnded' then
			if step == TutorialService.Step.ArenaStarted then
				result = { Step = TutorialService.Step.ArenaEnded, EggId = nil, AnimalId = state.AnimalId }
			end
		elseif name == 'ArenaCancelled' then
			if step == TutorialService.Step.ArenaStarted then
				result = { Step = TutorialService.Step.StartArena, EggId = nil, AnimalId = state.AnimalId }
			end
		elseif name == 'ContinueConfirmed' then
			if step == TutorialService.Step.ArenaEnded then
				result = { Step = TutorialService.Step.UpgradeAnimal, EggId = nil, AnimalId = state.AnimalId }
			end
		elseif name == 'AnimalUpgraded' then
			if step == TutorialService.Step.UpgradeAnimal and event.AnimalId == state.AnimalId then
				result = { Step = TutorialService.Step.LockBase, EggId = nil, AnimalId = state.AnimalId }
			end
		elseif name == 'BaseLocked' then
			if step == TutorialService.Step.LockBase then
				result = { Step = TutorialService.Step.Completed, EggId = nil, AnimalId = nil }
			end
		end
	end)
	return result
end

-- DeriveResume(persisted, lookup) -> {Step,EggId,AnimalId} for
-- join/rejoin: validates tracked ids against live lookups,
-- adopts an owned unhatched egg when the step needs one,
-- otherwise falls back along the chain (never invents
-- animals). `lookup` = { eggById(id), ownedUnhatchedEggId(),
-- animalById(id) }. Pure apart from the injected lookups —
-- specs drive it with fakes.
function TutorialService.DeriveResume(persisted: any, lookup: any): any
	local fallback: any = { Step = TutorialService.Step.BuyEgg, EggId = nil, AnimalId = nil }
	local out: any = nil
	pcall(function()
		if type(persisted) == 'table' and persisted.Completed == true then
			out = { Step = TutorialService.Step.Completed, EggId = nil, AnimalId = nil }
			return
		end
		local step = if type(persisted) == 'table' and type(persisted.Step) == 'string'
			then persisted.Step
			else TutorialService.Step.BuyEgg
		local eggId = if type(persisted) == 'table' then persisted.EggId else nil
		local animalId = if type(persisted) == 'table' then persisted.AnimalId else nil
		local liveEgg: any = nil
		local liveAnimal: any = nil
		pcall(function()
			if lookup ~= nil and type(eggId) == 'string' then
				liveEgg = lookup.eggById(eggId)
			end
		end)
		pcall(function()
			if lookup ~= nil and type(animalId) == 'string' then
				liveAnimal = lookup.animalById(animalId)
			end
		end)
		local function ownedEgg(): any
			local found: any = nil
			pcall(function()
				if lookup ~= nil then
					found = lookup.ownedUnhatchedEggId()
				end
			end)
			return found
		end
		if step == TutorialService.Step.BuyEgg then
			-- Out-of-order grace: already owns an unhatched egg.
			local owned = ownedEgg()
			if type(owned) == 'string' then
				out = { Step = TutorialService.Step.HatchEgg, EggId = owned, AnimalId = nil }
			else
				out = { Step = TutorialService.Step.BuyEgg, EggId = nil, AnimalId = nil }
			end
		elseif step == TutorialService.Step.WaitForEgg or step == TutorialService.Step.HatchEgg then
			if liveEgg ~= nil then
				out = { Step = step, EggId = eggId, AnimalId = nil }
			else
				local owned = ownedEgg()
				if type(owned) == 'string' then
					out = { Step = TutorialService.Step.HatchEgg, EggId = owned, AnimalId = nil }
				else
					out = fallback
				end
			end
		elseif
			step == TutorialService.Step.PickUpAnimal
			or step == TutorialService.Step.PlaceAnimal
			or step == TutorialService.Step.StartArena
			or step == TutorialService.Step.ArenaStarted
			or step == TutorialService.Step.ArenaEnded
			or step == TutorialService.Step.UpgradeAnimal
		then
			if liveAnimal ~= nil then
				out = { Step = step, EggId = nil, AnimalId = animalId }
			elseif liveEgg ~= nil then
				out = { Step = TutorialService.Step.HatchEgg, EggId = eggId, AnimalId = nil }
			else
				local owned = ownedEgg()
				if type(owned) == 'string' then
					out = { Step = TutorialService.Step.HatchEgg, EggId = owned, AnimalId = nil }
				else
					out = fallback
				end
			end
		elseif step == TutorialService.Step.LockBase then
			-- Lock state itself is re-read live by RecoverFor;
			-- here keep the step with whatever animal survived.
			if liveAnimal ~= nil then
				out = { Step = step, EggId = nil, AnimalId = animalId }
			else
				out = { Step = step, EggId = nil, AnimalId = nil }
			end
		else
			out = fallback
		end
	end)
	if out == nil then
		out = fallback
	end
	return out
end

-- --- Persistence ---------------------------------------------------------

local function _readPersisted(userId: number): any
	local data: any = nil
	pcall(function()
		if _playerService ~= nil then
			local profile = _playerService.GetPlayerData(userId)
			if type(profile) == 'table' then
				data = profile.Tutorial
			end
		end
	end)
	if type(data) ~= 'table' then
		return _defaultPersisted()
	end
	return {
		Completed = data.Completed == true,
		Step = if type(data.Step) == 'string' then data.Step else TutorialService.Step.BuyEgg,
		EggId = if type(data.EggId) == 'string' then data.EggId else nil,
		AnimalId = if type(data.AnimalId) == 'string' then data.AnimalId else nil,
	}
end

local function _writePersisted(userId: number, state: any)
	pcall(function()
		if _playerService ~= nil and type(state) == 'table' then
			_playerService.SetTutorial(userId, {
				Completed = state.Step == TutorialService.Step.Completed,
				Step = state.Step,
				EggId = state.EggId,
				AnimalId = state.AnimalId,
			})
		end
	end)
end

-- --- Target tagging (strictly per-player) -------------------------------

-- Tagged target instance per player: untagging is scoped to
-- the acting player's own previous target, NEVER a global
-- clear — one player's purchase/leave/completion must not
-- strip another player's highlight (their tag is restored
-- only by their own next transition, so a global clear would
-- visibly flicker multiplayer tutorials).
local _taggedByUser: { [number]: Instance? } = {}

local function _untagPlayer(userId: number)
	pcall(function()
		local inst = _taggedByUser[userId]
		_taggedByUser[userId] = nil
		if typeof(inst) == 'Instance' then
			pcall(function()
				CollectionService:RemoveTag(inst, TutorialService.TagFor(userId))
			end)
		end
	end)
end

local function _modelForEgg(eggId: string?): Instance?
	local model: Instance? = nil
	pcall(function()
		if _spawnService ~= nil and type(eggId) == 'string' then
			local egg = _spawnService.GetEgg(eggId)
			if type(egg) == 'table' and typeof(egg.model) == 'Instance' then
				model = egg.model
			end
		end
	end)
	return model
end

local function _modelForAnimal(animalId: string?): Instance?
	local model: Instance? = nil
	pcall(function()
		if _animalService ~= nil and type(animalId) == 'string' then
			local animal = _animalService.Get(animalId)
			if type(animal) == 'table' and typeof(animal.model) == 'Instance' then
				model = animal.model
			end
		end
	end)
	return model
end

local function _retargetTag(userId: number)
	pcall(function()
		local state = _active[userId]
		_untagPlayer(userId)
		if state == nil then
			return
		end
		local model: Instance? = nil
		if state.EggId ~= nil then
			model = _modelForEgg(state.EggId)
		elseif state.AnimalId ~= nil then
			model = _modelForAnimal(state.AnimalId)
		end
		if model ~= nil and model.Parent ~= nil then
			CollectionService:AddTag(model, TutorialService.TagFor(userId))
			_taggedByUser[userId] = model
		end
	end)
end

-- --- Publish ---------------------------------------------------------------

-- First Empty arena slot id for the player's base (a display
-- suggestion only — completion accepts ANY arena slot holding
-- the tracked animal). Falls back to the first arena slot.
local function _suggestArenaSlotId(userId: number): string?
	local found: string? = nil
	pcall(function()
		if _baseService == nil or _slotService == nil then
			return
		end
		local base = _baseService.GetPlayerBase(userId)
		if type(base) ~= 'table' then
			return
		end
		local slots: any = base.arenaSlots
		if type(slots) ~= 'table' then
			return
		end
		local order: { any } = {}
		for _, slot in pairs(slots) do
			order[#order + 1] = slot
		end
		table.sort(order, function(a: any, b: any)
			return (a.arenaIndex or 0) < (b.arenaIndex or 0)
		end)
		for _, slot in ipairs(order) do
			if found == nil and type(slot) == 'table' and type(slot.id) == 'string' then
				found = slot.id
			end
			if type(slot) == 'table' and slot.state == SlotType.State.Empty and type(slot.id) == 'string' then
				found = slot.id
				break
			end
		end
	end)
	return found
end

local function _baseIdOf(userId: number): string?
	local baseId: string? = nil
	pcall(function()
		if _playerService ~= nil then
			local profile = _playerService.GetPlayerData(userId)
			if type(profile) == 'table' and type(profile.BaseId) == 'string' then
				baseId = profile.BaseId
			end
		end
	end)
	return baseId
end

-- Live slot id holding a tracked animal (the upgrade-step
-- target). The client's beam/ring resolve the STAND from the
-- snapshot SlotId because the tracked animal MODEL is not
-- parented under its stand (world-positioned), so climbing
-- from the tag can never reach the MenuPart. Resolved at
-- publish time (republish follows every transition); nil
-- when unresolvable — the client keeps its tag-climb
-- fallback. Never throws.
local function _slotIdOfAnimal(animalId: string?): string?
	local found: string? = nil
	pcall(function()
		if _slotService == nil or type(animalId) ~= 'string' or animalId == '' then
			return
		end
		local slot: any = _slotService.FindSlotByOccupant(animalId)
		if type(slot) == 'table' and type(slot.id) == 'string' then
			found = slot.id
		end
	end)
	return found
end

function TutorialService.PublishTo(target: any)
	pcall(function()
		local player: Player? = nil
		local userId: number? = nil
		if typeof(target) == 'Instance' and (target :: Instance):IsA('Player') then
			player = target :: Player
			userId = player.UserId
		elseif type(target) == 'number' then
			userId = target
			player = Players:GetPlayerByUserId(target)
		end
		if player == nil or userId == nil then
			return
		end
		local state = _active[userId]
		if state == nil then
			return
		end
		local snapshot: any = {
			Step = state.Step,
			EggId = state.EggId,
			AnimalId = state.AnimalId,
			SlotId = nil,
			BaseId = _baseIdOf(userId),
			-- Deterministic per-player BuyEgg target (canonical
			-- starter rarity from EggConfig). Informational: the
			-- client derives the same value from the same
			-- config; the server never invents egg targets.
			StarterEggRarity = TutorialService.StarterEggRarity(),
		}
		if state.Step == TutorialService.Step.PlaceAnimal then
			snapshot.SlotId = _suggestArenaSlotId(userId)
		elseif state.Step == TutorialService.Step.UpgradeAnimal then
			snapshot.SlotId = _slotIdOfAnimal(state.AnimalId)
		end
		Remotes.FireClient(player, Remotes.Names.TutorialState, snapshot)
	end)
end

-- --- Transitions ------------------------------------------------------------

-- NOTE: the tutorial step sting is PERSONAL and plays on the
-- acting player's client (TutorialController._playTutorialSound
-- on the TutorialState push — one listener, no duplicates).
-- An earlier design played it here via a server-mounted
-- PlayerGui clone; that path is deleted so the server NEVER
-- calls :Play() on tutorial audio.

local function _applyTransition(userId: number, next: any, viaSkip: boolean?)
	-- Runtime + persistence commit even when the player
	-- instance is gone (rejoin reconciles from it); the push
	-- needs a live player and is skipped otherwise.
	_active[userId] = next
	_writePersisted(userId, next)
	local player: Player? = nil
	pcall(function()
		player = Players:GetPlayerByUserId(userId)
	end)
	if player ~= nil then
		_retargetTag(userId)
		TutorialService.PublishTo(player)
		-- Step-change sting: the CLIENT plays it exactly once
		-- per real step change on this push (see
		-- TutorialController) — the server stays silent so the
		-- sting can never double-play.
	end
	Debug.Log('TS', 'advanced', {
		userId = tostring(userId),
		step = tostring(next.Step),
		egg = tostring(next.EggId),
		animal = tostring(next.AnimalId),
	})
	-- Multiplayer trace: when a player buys THEIR tutorial egg,
	-- log their identity + their actual egg id (proves per-player
	-- tracking — no shared/global egg variable).
	if next.Step == TutorialService.Step.WaitForEgg then
		local who = tostring(userId)
		pcall(function()
			local livePlayer = Players:GetPlayerByUserId(userId)
			if livePlayer ~= nil then
				who = (livePlayer :: Player).Name
			end
		end)
		Debug.Log('TutorialEgg', ('player=%s purchased tutorial eggId=%s'):format(who, tostring(next.EggId)))
	end
	if next.Step == TutorialService.Step.Completed then
		pcall(function()
			_active[userId] = nil
		end)
		_untagPlayer(userId)
		Debug.Log('TS', 'completed', { userId = tostring(userId) })
		-- Funnel: completion committed above (persisted +
		-- cleared). A skip is NOT a completion — it logs the
		-- honest TutorialSkipped terminal instead.
		pcall(function()
			local completedPlayer: Player? = nil
			pcall(function()
				completedPlayer = Players:GetPlayerByUserId(userId)
			end)
			if completedPlayer then
				if viaSkip == true then
					FunnelService:LogStep(completedPlayer, 'Onboarding', 'TutorialSkipped', nil)
				else
					FunnelService:LogStep(completedPlayer, 'Onboarding', 'TutorialCompleted', nil)
					-- Player monitoring: real completion only
					-- (skips stay silent here too).
					pcall(PlayerLogger.LogMilestone, completedPlayer, 'TutorialCompleted', nil)
				end
			end
		end)
	end
end

local function _onBusEvent(name: string, payload: any)
	pcall(function()
		if type(payload) ~= 'table' then
			return
		end
		local userId: any = payload.UserId or payload.OwnerUserId
		if type(userId) ~= 'number' then
			return
		end
		local state = _active[userId]
		if state == nil then
			return
		end
		-- Lock completion additionally requires the locked base
		-- to be the player's own (defense in depth — the bus
		-- only fires for owner presses, but steps must never
		-- complete on another base's event).
		if name == 'BaseLocked' and type(payload.BaseId) == 'string' then
			local ownBase: string? = nil
			pcall(function()
				if _baseService ~= nil then
					local base = _baseService.GetPlayerBase(userId)
					if type(base) == 'table' then
						ownBase = base.id
					end
				end
			end)
			if ownBase ~= nil and payload.BaseId ~= ownBase then
				return
			end
		end
		local next = TutorialService.NextStep(state, {
			Name = name,
			EggId = payload.EggId,
			AnimalId = payload.AnimalId,
			SlotId = payload.SlotId,
			BaseId = payload.BaseId,
		})
		if next ~= nil then
			_applyTransition(userId, next)
		end
	end)
end

-- --- Recovery ---------------------------------------------------------------

-- Shared registry lookups for DeriveResume callers. Record
-- EXISTENCE (not model liveness) decides whether a tracked
-- egg/animal is still tutorial-relevant:
--   * a hatching egg has state Opening with a DESTROYED model
--     for ~5s (EggService destroys it before the roulette);
--     treating that as "gone" is what used to reset HatchEgg
--     -> BuyEgg mid-hatch. The record is dropped only when
--     the egg is genuinely gone (consumed/expired/destroyed).
--   * an arena-deployed animal's stand model may be parked
--     while the record (and the fight) is alive.
-- Model liveness is required ONLY for adopting a *replacement*
-- egg (it must be interactable) and for tag publishing (the
-- tag helper already nil-guards).
local function _makeLookup(userId: number): any
	local lookup: any = {}
	function lookup.eggById(id: string): any?
		local found: any? = nil
		pcall(function()
			local egg = _spawnService.GetEgg(id)
			if type(egg) == 'table' then
				found = egg
			end
		end)
		return found
	end
	function lookup.animalById(id: string): any?
		local found: any? = nil
		pcall(function()
			local animal = _animalService.Get(id)
			if type(animal) == 'table' then
				found = animal
			end
		end)
		return found
	end
	function lookup.ownedUnhatchedEggId(): string?
		local found: string? = nil
		pcall(function()
			local profile = _playerService.GetPlayerData(userId)
			local rows = profile and profile.LuckyBlocks or nil
			if type(rows) ~= 'table' then
				return
			end
			for _, row in ipairs(rows) do
				if type(row) == 'table' and type(row.Id) == 'string' then
					local egg = _spawnService.GetEgg(row.Id)
					if
						type(egg) == 'table'
						and (egg.state == 'Available' or egg.state == 'Traveling' or egg.state == 'Placed')
						and typeof(egg.model) == 'Instance'
						and egg.model.Parent ~= nil
					then
						found = row.Id
						break
					end
				end
			end
		end)
		return found
	end
	return lookup
end

-- Validate tracked refs against live registries; adopt an
-- owned unhatched egg when the step needs an egg; otherwise
-- fall back along the chain. Never invents animals. A
-- fallback all the way to BuyEgg from a later step is always
-- loudly warned (that path must stay exceptional — normal
-- lifecycle events must never produce it).
function TutorialService.RecoverFor(userId: number)
	pcall(function()
		local state = _active[userId]
		if state == nil then
			return
		end
		if not _services() then
			return
		end
		local lookup = _makeLookup(userId)
		local resumed =
			TutorialService.DeriveResume({ Step = state.Step, EggId = state.EggId, AnimalId = state.AnimalId }, lookup)
		-- LockBase re-check: a lock achieved while we looked
		-- away completes immediately (canonical IsLocked read).
		if resumed.Step == TutorialService.Step.LockBase then
			local locked = false
			pcall(function()
				local base = _baseService.GetPlayerBase(userId)
				if base ~= nil then
					local lockService: any = nil
					local okLock, svc = pcall(function()
						return require(game:GetService('ServerScriptService').Base.BaseLockService)
					end)
					if okLock and svc ~= nil then
						lockService = svc
						locked = lockService.IsLocked(base.id) == true
					end
				end
			end)
			if locked then
				resumed = { Step = TutorialService.Step.Completed, EggId = nil, AnimalId = nil }
			end
		end
		if resumed.Step ~= state.Step or resumed.EggId ~= state.EggId or resumed.AnimalId ~= state.AnimalId then
			if resumed.Step == TutorialService.Step.BuyEgg and state.Step ~= TutorialService.Step.BuyEgg then
				Debug.Warn('TS', 'recovery fell back to BuyEgg (must stay exceptional)', {
					userId = tostring(userId),
					fromStep = tostring(state.Step),
					fromEgg = tostring(state.EggId),
					fromAnimal = tostring(state.AnimalId),
				})
			end
			_applyTransition(userId, resumed)
		else
			_retargetTag(userId)
		end
	end)
end

-- --- Public API ------------------------------------------------------------------

function TutorialService.GetStep(userId: number): string?
	local state = _active[userId]
	return state and state.Step or nil
end

function TutorialService.GetState(userId: number): any?
	local state = _active[userId]
	if state == nil then
		return nil
	end
	return { Step = state.Step, EggId = state.EggId, AnimalId = state.AnimalId }
end

-- Client intents. 'State' re-publishes; 'Continue' and
-- 'Skip' are accepted ONLY while the server holds a matching
-- active state (server-gated, never trusted blindly).
function TutorialService.HandleAction(player: Player, payload: any)
	pcall(function()
		if typeof(player) ~= 'Instance' or not (player :: Instance):IsA('Player') then
			return
		end
		local userId = (player :: Player).UserId
		local action: string? = nil
		pcall(function()
			if type(payload) == 'table' then
				action = payload.Action
			end
		end)
		if action == 'State' then
			TutorialService.PublishTo(player)
			return
		end
		if action == 'Continue' then
			local state = _active[userId]
			if state == nil then
				return
			end
			local next = TutorialService.NextStep(state, { Name = 'ContinueConfirmed' })
			if next ~= nil then
				_applyTransition(userId, next)
			end
			return
		end
		if action == 'Skip' then
			local state = _active[userId]
			if state == nil or state.Step == TutorialService.Step.Completed then
				return
			end
			-- Skip is a real completion: persisted Completed,
			-- runtime cleared, untagged, final snapshot pushed
			-- (the client tears everything down on it). Never
			-- replays on rejoin (Completed short-circuits resume).
			local done = { Step = TutorialService.Step.Completed, EggId = nil, AnimalId = nil }
			_applyTransition(userId, done, true)
			Debug.Log('TS', 'skipped', { userId = tostring(userId) })
			return
		end
		Debug.Log('TS', 'unknown action ignored', { action = tostring(action) })
	end)
end

-- Join/resume entry (called by bootstrap after load + base +
-- restore). Starts fresh BuyEgg for new players; validates +
-- adopts-or-falls-back for returners; skips completed.
function TutorialService.ResumeForPlayer(player: Player)
	pcall(function()
		if typeof(player) ~= 'Instance' or not (player :: Instance):IsA('Player') then
			return
		end
		local userId = (player :: Player).UserId
		if not _services() then
			return
		end
		local persisted = _readPersisted(userId)
		if persisted.Completed == true then
			_active[userId] = nil
			return
		end
		local lookup = _makeLookup(userId)
		local resumed = TutorialService.DeriveResume(persisted, lookup)
		_active[userId] = resumed
		_writePersisted(userId, resumed)
		_retargetTag(userId)
		TutorialService.PublishTo(player)
		-- Multiplayer trace: every joining player's tutorial
		-- target is the SAME canonical starter rarity, but the
		-- tracked state object is their own.
		Debug.Log('TutorialEgg', ('player=%s lowestEgg=%s tutorial target initialized step=%s'):format(
				player.Name,
				TutorialService.StarterEggRarity(),
				tostring(resumed.Step)
			))
		Debug.Log('TS', 'resumed', {
			userId = tostring(userId),
			step = tostring(resumed.Step),
		})
		-- Funnel: onboarding entry. Fresh BuyEgg starts log
		-- TutorialStarted; mid-tutorial rejoins resume
		-- silently (no fake restarts); completed players
		-- returned early above and never reach here.
		if resumed.Step == TutorialService.Step.BuyEgg then
			pcall(function()
				FunnelService:LogStep(player, 'Onboarding', 'TutorialStarted', nil)
			end)
		end
	end)
end

function TutorialService.ForgetPlayer(userId: number)
	pcall(function()
		_active[userId] = nil
	end)
	-- Only THEIR highlight goes: other players keep theirs.
	_untagPlayer(userId)
end

function TutorialService.Init()
	if _started then
		return
	end
	_started = true
	_services()
	-- Asset fetch yields: never stall boot on it.
	task.spawn(_publishBeamTemplate)
	local channels: { string } = {
		'EggPurchased',
		'EggPlaced',
		'EggHatched',
		'AnimalPickedUp',
		'AnimalPlaced',
		'ArenaStarted',
		'ArenaEnded',
		'ArenaCancelled',
		'AnimalUpgraded',
		'BaseLocked',
	}
	for _, name in ipairs(channels) do
		local channel = name
		TutorialSignals.Connect(channel, function(payload: any)
			_onBusEvent(channel, payload)
		end)
	end
	pcall(function()
		local remotes = ReplicatedStorage:WaitForChild('Remotes', 10)
		local action = remotes and (remotes :: Instance):WaitForChild(Remotes.Names.TutorialAction, 10) or nil
		if action ~= nil and (action :: Instance):IsA('RemoteEvent') then
			((action :: Instance) :: RemoteEvent).OnServerEvent:Connect(function(player: Player, payload: any)
				TutorialService.HandleAction(player, payload)
			end)
		end
	end)
	-- NOTE: personal-SFX mirroring (Pop/Approved/LevelUp into
	-- ReplicatedStorage.Assets.Sfx) lives in ONE place —
	-- bootstrap section 5d. This service runs no mirror.
	Debug.Log('TS', 'TutorialService initialized', {})
end

function TutorialService.Start()
	if _tickConn ~= nil then
		return
	end
	-- 1 Hz recovery sweep over ACTIVE tutorial players only
	-- (registry lookups by id — never Workspace scans). Keeps
	-- arrows off destroyed instances and adopts replacements.
	_tickConn = RunService.Heartbeat:Connect(function(dt: number)
		_tickAccum += dt
		if _tickAccum < 1 then
			return
		end
		_tickAccum = 0
		pcall(function()
			for userId, _ in pairs(_active) do
				TutorialService.RecoverFor(userId)
			end
		end)
	end)
	Debug.Log('TS', 'TutorialService started', {})
end

-- TEST seam: inject runtime state (specs only).
function TutorialService._TestSetState(userId: number, state: any?)
	if state == nil then
		_active[userId] = nil
	else
		_active[userId] = { Step = state.Step, EggId = state.EggId, AnimalId = state.AnimalId }
	end
end

-- TEST seam: drop runtime state (specs only).
function TutorialService._TestReset()
	table.clear(_active)
	table.clear(_taggedByUser)
	_tickAccum = 0
end

return table.freeze(TutorialService)
