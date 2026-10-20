--!strict
--!native
--[[
	ArenaService (continuous raid shell)
	====================================
	Server-authoritative Arena RAID: Adventurer entry point,
	raid menu state, raid start/cancel validation, and the
	multi-stage session combat runs inside.

	RAID MODEL (replaces per-level selection):
	  * The player locks ONE loadout (occupied ARENA slots)
	    and starts ONE raid. Every raid begins at stage 1.
	  * The server advances the SAME session stage by stage
	    (1 -> 2 -> ... -> MaxLevel). The client never selects
	    stages and never sends "start next stage".
	  * Raid HP is run state (session.raidHP / battle
	    CurrentHealth). Persistent animals are never mutated;
	    combatants are temporary tables holding canonical
	    stats + carried HP. Dead stays dead for the run.
  * Stage wins ACCUMULATE (never pay): each cleared stage
    adds its configured contribution (first/repeat cash +
    XP, selected via the raid's first-clear cursor) to the
    session's temporary rewardAccumulator. No EconomyService
    call, no XP grant, no toast mid-raid.
  * Terminal settlement is collective and PROGRESSIVE:
    both RAID COMPLETE and raid FAILED settle the accumulator
    with ONE cash transaction + ONE XP grant (+ stage history
    for every cleared stage). A wipe on stage N pays stages
    1..N-1; only the failed stage is forfeited. An empty
    accumulator (wipe on stage 1) settles $0 / 0 XP. Leave /
    silent-cancel paths never reach settlement (abandoned runs
    forfeit). Final-stage win = RAID COMPLETE.
	  * HighestCompleted persists as the highest stage ever
	    WON (history + first/repeat selection). LastReached
	    persists as the highest stage ever REACHED (win or
	    lose — drives paid restarts). Neither is a gate: a
	    normal raid starts at stage 1; paid restarts start at
	    the server-authorized warmup/last stage.

	Authority model:
	  ArenaConfig (stage catalog + enemy rosters + rewards)
	        |
	        +-- server re-resolves EVERYTHING per stage
	        v
  StartRaid: validate player -> base -> session ->
              carry/steal -> team -> purchase (Buy1/Buy2) ->
              stage-N battle (atomic)
  Stage win: snapshot raid HP -> accumulate contribution ->
             final ? complete (settle once) : advance (same
             sessionId, stageGeneration + 1)

	Stale safety: (sessionId, stageGeneration) tokens.
	Every battle-end/cancel callback must match BOTH, or it
	is ignored with no reward and no state change.

	Team source: the player's OCCUPIED ARENA slots
	(ResolveArenaTeam over base.arenaSlots, resolved through
	AnimalService, deterministic arenaIndex order). Animals
	move Normal <-> Arena through the canonical grab/place
	pipeline; exactly one authoritative record exists and
	its location IS the slotId. The raid locks an immutable
	member snapshot at start; mid-raid sells/moves/upgrades/
	steals cannot mutate active combatants (stats freeze at
	build; HP lives only in the session).

	Boundaries respected:
	  * No second AnimalService / economy / persistence /
	    slot system. Cash/XP move only through
	    EconomyService / ArenaProgressionService.
	  * No timers, no polling: prompt Triggered, remote
	    actions, battle-end callbacks, and player lifecycle
	    drive everything. Stage transitions are synchronous
	    inside the win settlement (no delayed tasks).
  * Adventurer: prefers an authored `Base/Adventurer`
    (Model or BasePart), else the short alias `Base/Adv`;
    only when both are absent is a clearly marked temporary
    NPC created in code (reused across assignments, never
    duplicated).
]]

local ReplicatedStorage = game:GetService('ReplicatedStorage')
local Players = game:GetService('Players')

local ArenaConfig = require(ReplicatedStorage.Config.World.Arena)
local ArenaPresentationConfig = require(ReplicatedStorage.Config.World.ArenaFeel)
local PromptConfig = require(ReplicatedStorage.Config.World.Prompts)
local SlotType = require(ReplicatedStorage.Types.SlotType)
local Remotes = require(ReplicatedStorage.Utility.Remotes)
local Validation = require(ReplicatedStorage.Utility.Validation)
local BigNumber = require(ReplicatedStorage.Utility.BigNumber)
local TransactionReason = require(ReplicatedStorage.Types.TransactionReason)
local Debug = require(ReplicatedStorage.Utility.Debug)
local AnimalStats = require(ReplicatedStorage.Utility.AnimalStats)
local TutorialSignals = require(script.Parent.Parent.Tutorial.TutorialSignals)
-- Funnel analytics (leaf module — never gameplay-critical).
local FunnelService = require(script.Parent.Parent.FunnelService)
-- Player monitoring (Discord embeds + registry; leaf module,
-- never gameplay-critical).
local PlayerLogger = require(script.Parent.Parent.PlayerLogger.PlayerLogger)

local ArenaService = {}

local playerServiceRef: any = nil
local baseServiceRef: any = nil
local animalServiceRef: any = nil
local slotServiceRef: any = nil
local carryRegistryRef: any = nil
local stealServiceRef: any = nil
local notificationServiceRef: any = nil
local progressionServiceRef: any = nil
local economyServiceRef: any = nil
local battleServiceRef: any = nil

-- Active raids: [userId] -> raid session. One at a time
-- per player; (sessionId, stageGeneration) is the token
-- stale callbacks must validate against. A session owns:
--   sessionId, userId, kind='Raid', arenaLevel (current
--   stage, always starts 1), maxLevel, stageGeneration,
--   state, team (immutable loadout snapshot), raidHP /
--   raidAlive (run HP by UniqueId — NEVER written back to
--   persistent animals), rewardedStages / settledStages
--   (per-stage idempotency), areaReady, startedAt, battle
--   (current stage battle only).
local sessions: { [number]: { [string]: any } } = {}
local nextSessionId = 1
-- Last terminal raid outcome per user, surfaced in state so
-- a client can render results after the session is gone.
-- Cleared on the next raid start / forget.
local lastRaid: { [number]: { [string]: any } } = {}
local started = false

function ArenaService.SetPlayerService(svc: any)
	playerServiceRef = svc
end

function ArenaService.SetBaseService(svc: any)
	baseServiceRef = svc
end

function ArenaService.SetAnimalService(svc: any)
	animalServiceRef = svc
end

function ArenaService.SetSlotService(svc: any)
	slotServiceRef = svc
end

function ArenaService.SetCarryRegistry(svc: any)
	carryRegistryRef = svc
end

function ArenaService.SetStealService(svc: any)
	stealServiceRef = svc
end

function ArenaService.SetNotificationService(svc: any)
	notificationServiceRef = svc
end

function ArenaService.SetProgressionService(svc: any)
	progressionServiceRef = svc
end

function ArenaService.SetEconomyService(svc: any)
	economyServiceRef = svc
end

function ArenaService.SetBattleService(svc: any)
	battleServiceRef = svc
end

local function notifyWarning(player: Player, id: string, data: any)
	if notificationServiceRef then
		pcall(notificationServiceRef.NotifyWarning, player, id, data or {})
	end
end

local function notifySuccess(player: Player, id: string, data: any)
	if notificationServiceRef then
		pcall(notificationServiceRef.NotifySuccess, player, id, data or {})
	end
end

local function formatCash(amount: string): string
	local ok, text = pcall(BigNumber.Format, amount)
	if ok and type(text) == 'string' then
		return '$' .. text
	end
	return '$' .. tostring(amount)
end

-- --- Adventurer ------------------------------------------------------

local function ensurePrompt(parent: Instance, hostName: string): ProximityPrompt?
	local existing: ProximityPrompt? = nil
	pcall(function()
		existing = parent:FindFirstChildOfClass('ProximityPrompt')
	end)
	if existing ~= nil then
		return existing
	end
	local prompt: ProximityPrompt? = nil
	pcall(function()
		local created = Instance.new('ProximityPrompt')
		created.ActionText = PromptConfig.Arena.ActionText
		created.ObjectText = PromptConfig.Arena.ObjectText
		created.HoldDuration = PromptConfig.Arena.HoldDuration
		created.MaxActivationDistance = PromptConfig.Arena.MaxActivationDistance
		created.RequiresLineOfSight = PromptConfig.Arena.RequiresLineOfSight
		created.Parent = parent
		prompt = created
	end)
	if prompt ~= nil then
		Debug.Warn('Arena', ('Adventurer prompt installed at %s'):format(hostName))
	end
	return prompt
end

-- Resolve the Adventurer interaction point for a base.
-- Prefers authored content; creates ONE clearly marked
-- temporary NPC only when nothing exists. Idempotent:
-- repeated calls reuse the existing instance and never
-- duplicate. Returns true when a prompt is wired.
-- Resolve the base's Adventurer/Adv host with the canonical
-- priority (authored Adventurer -> authored Adv -> temporary
-- either name). Shared by EnsureAdventurer and the raid Adv
-- hide/restore below so both always target the SAME instance.
local function _findAdvHost(base: any): Instance?
	local host: Instance? = nil
	pcall(function()
		if type(base) ~= 'table' or typeof(base.folder) ~= 'Instance' then
			return
		end
		local folder = base.folder :: Instance
		local temp: Instance? = nil
		local advAlias: Instance? = nil
		for _, child in ipairs(folder:GetChildren()) do
			local isTemp = false
			pcall(function()
				isTemp = child:GetAttribute('ArenaTemporary') == true
			end)
			if child.Name == 'Adventurer' then
				if not isTemp then
					host = child
					break
				elseif temp == nil then
					temp = child
				end
			elseif child.Name == 'Adv' then
				if not isTemp then
					if advAlias == nil then
						advAlias = child
					end
				elseif temp == nil then
					temp = child
				end
			end
		end
		if host == nil then
			host = if advAlias ~= nil then advAlias else temp
		end
	end)
	return host
end

-- --- Raid Adv visibility (per-player, server-authoritative) --------------

-- While a player's raid runs, ONLY their own base's
-- Adventurer/Adv hides (fully transparent); every other
-- base's Adv is untouched (per-userId records, per-base
-- hosts). Original Transparency values are saved per part —
-- NEVER assumed 0 — and restored EXACTLY on every terminal
-- path (win, loss, retreat, silent cancel, leave). Billboard
-- labels (e.g. the temporary NPC's "Adventurer" tag) disable
-- and restore the same way. All server-driven property
-- changes, so hiding replicates to everyone. Everything is
-- pcall-guarded; destroyed/missing parts restore-skip
-- silently. The entry prompt stays live (opening the menu
-- mid-raid is already rejected as already-active).
local _advHidden: {
	[number]: {
		baseId: string,
		parts: { { part: BasePart, transparency: number } },
		boards: { { gui: BillboardGui, enabled: boolean } },
	},
} = {}

local function _restoreAdv(userId: number): boolean
	if type(userId) ~= 'number' then
		return false
	end
	local record = _advHidden[userId]
	_advHidden[userId] = nil
	if type(record) ~= 'table' then
		return false
	end
	pcall(function()
		for _, entry in ipairs((record :: any).parts or {}) do
			local part = (entry :: any).part
			local transparency = (entry :: any).transparency
			if typeof(part) == 'Instance' and (part :: Instance).Parent ~= nil and (part :: Instance):IsA('BasePart') then
				if type(transparency) == 'number' then
					pcall(function()
						(part :: BasePart).Transparency = transparency
					end)
				end
			end
		end
		for _, entry in ipairs((record :: any).boards or {}) do
			local gui = (entry :: any).gui
			local enabled = (entry :: any).enabled
			if typeof(gui) == 'Instance' and (gui :: Instance).Parent ~= nil and (gui :: Instance):IsA('BillboardGui') then
				if type(enabled) == 'boolean' then
					pcall(function()
						(gui :: BillboardGui).Enabled = enabled
					end)
				end
			end
		end
	end)
	return true
end

local function _hideAdv(userId: number, base: any): boolean
	if type(userId) ~= 'number' then
		return false
	end
	-- Defensive: never stack on a leaked record (restore is
	-- terminal-paired, so this is a no-op in practice).
	pcall(_restoreAdv, userId)
	local hidAny = false
	pcall(function()
		local host = _findAdvHost(base)
		if host == nil then
			return
		end
		local baseId = '?'
		pcall(function()
			if type(base) == 'table' and type(base.id) == 'string' then
				baseId = base.id
			end
		end)
		local record = {
			baseId = baseId,
			parts = {},
			boards = {},
		}
		local function takePart(part: BasePart)
			if (part :: BasePart).Parent == nil then
				return
			end
			local okT, original: number? = nil, nil
			pcall(function()
				original = (part :: BasePart).Transparency
				okT = true
			end)
			if okT == true and type(original) == 'number' then
				table.insert(record.parts, { part = part, transparency = original })
				pcall(function()
					(part :: BasePart).Transparency = 1
				end)
				hidAny = true
			end
		end
		if (host :: Instance):IsA('BasePart') then
			takePart(host :: BasePart)
		end
		for _, descendant in ipairs((host :: Instance):GetDescendants()) do
			if descendant:IsA('BasePart') then
				takePart(descendant)
			elseif descendant:IsA('BillboardGui') then
				local gui = descendant :: BillboardGui
				local okE, wasEnabled: boolean? = nil, nil
				pcall(function()
					wasEnabled = gui.Enabled
					okE = true
				end)
				if okE == true and type(wasEnabled) == 'boolean' then
					table.insert(record.boards, { gui = gui, enabled = wasEnabled })
					pcall(function()
						gui.Enabled = false
					end)
				end
			end
		end
		if hidAny or #record.boards > 0 then
			_advHidden[userId] = record
		end
	end)
	return hidAny
end

-- TEST-ONLY seams (headless specs drive hide/restore against
-- fake base folders; live paths stay untouched).
function ArenaService._TestHideAdv(userId: number, base: any): boolean
	return _hideAdv(userId, base)
end

function ArenaService._TestRestoreAdv(userId: number): boolean
	return _restoreAdv(userId)
end

function ArenaService._TestAdvHidden(userId: number): boolean
	return _advHidden[userId] ~= nil
end

function ArenaService.EnsureAdventurer(base: any): boolean
	if type(base) ~= 'table' or typeof(base.folder) ~= 'Instance' then
		Debug.Warn('Arena', 'EnsureAdventurer: base has no folder')
		return false
	end
	local folder = base.folder :: Instance
	local host: Instance? = nil
	local ok = pcall(function()
		host = _findAdvHost(base)
	end)
	if not ok then
		warn(('[Arena] EnsureAdventurer: folder scan failed for base=%s'):format(tostring(base.id)))
		return false
	end
	if host == nil then
		-- Temporary code-built greeter: anchored, non-solid,
		-- beside the base spawn. Replaced by authored content
		-- later (which takes precedence above).
		local created: Instance? = nil
		local spawnCf: CFrame? = nil
		pcall(function()
			spawnCf = (base :: any).spawnCFrame
		end)
		if spawnCf == nil then
			warn(
				('[Arena] EnsureAdventurer: base=%s has no spawnCFrame; cannot place temporary NPC'):format(
					tostring(base.id)
				)
			)
			return false
		end
		local placed, err = pcall(function()
			local holder = ArenaPresentationConfig.AdventurerPlaceholder
			local part = Instance.new('Part')
			part.Name = 'Adventurer'
			part:SetAttribute('ArenaTemporary', true)
			part.Size = holder.Size
			part.Anchored = true
			part.CanCollide = false
			part.CanTouch = false
			part.CanQuery = false
			part.BrickColor = BrickColor.new(holder.BrickColorName)
			part.CFrame = (spawnCf :: CFrame) + holder.Offset
			local billboard = Instance.new('BillboardGui')
			billboard.Size = holder.BillboardSize
			billboard.StudsOffset = holder.BillboardOffset
			billboard.AlwaysOnTop = true
			local label = Instance.new('TextLabel')
			label.Size = UDim2.fromScale(1, 1)
			label.BackgroundTransparency = 1
			label.Text = 'Adventurer'
			label.TextScaled = true
			label.Font = holder.Font
			label.TextColor3 = holder.TextColor
			label.TextStrokeTransparency = holder.TextStrokeTransparency
			label.Parent = billboard
			billboard.Parent = part
			part.Parent = folder
			created = part
		end)
		if not placed or created == nil then
			warn(
				('[Arena] EnsureAdventurer: temporary NPC creation failed base=%s: %s'):format(
					tostring(base.id),
					tostring(err)
				)
			)
			return false
		end
		host = created
				Debug.Warn('Arena', ('Temporary Adventurer created for base=%s at %s (replace with authored Base/Adventurer or Base/Adv)'):format(
				tostring(base.id),
				(host :: Instance):GetFullName()
			))
	end
	-- Wire the prompt: directly on a BasePart, else on the
	-- first BasePart inside a Model.
	local promptHost: Instance? = nil
	if (host :: Instance):IsA('BasePart') then
		promptHost = host
	else
		pcall(function()
			promptHost = (host :: Instance):FindFirstChildWhichIsA('BasePart', true)
		end)
	end
	if promptHost == nil then
				Debug.Warn('Arena', ('EnsureAdventurer: no BasePart to host prompt at %s'):format((host :: Instance):GetFullName()))
		return false
	end
	local prompt = ensurePrompt(promptHost, (promptHost :: Instance):GetFullName())
	if prompt == nil then
		return false
	end
	local connected = false
	pcall(function()
		connected = (prompt :: ProximityPrompt):GetAttribute('ArenaWired') == true
	end)
	if not connected then
		local promptInst = prompt :: ProximityPrompt
		pcall(function()
			promptInst:SetAttribute('ArenaWired', true)
		end)
		-- NOTE: this Connect must be its own statement. A
		-- prior revision fused it onto the pcall above as
		-- `pcall(...)(prompt).Triggered:Connect(...)`, which
		-- calls pcall's boolean return as a function, errors,
		-- and silently never connects (bootstrap wraps this
		-- whole function in pcall) — the prompt fired nothing.
		promptInst.Triggered:Connect(function(player: Player)
			Debug.Log('Arena', 'Adventurer interaction detected', { player = player.Name })
			ArenaService.OpenArena(player)
		end)
		Debug.Log('Arena', 'Adventurer prompt connection installed', {
			prompt = promptInst:GetFullName(),
		})
	end
	return true
end

-- --- Team resolution ---------------------------------------------------

-- Authoritative NORMAL team (explicit semantics): animals in
-- the player's OCCUPIED normal slots. Kept for diagnostics;
-- expeditions use ResolveArenaTeam below.
function ArenaService.ResolveTeam(userId: number): { [string]: any }
	local empty = { members = {}, count = 0 }
	if type(userId) ~= 'number' or not baseServiceRef or not slotServiceRef or not animalServiceRef then
		return empty
	end
	local base: any = nil
	pcall(function()
		base = baseServiceRef.GetBaseByOwner(userId)
	end)
	if type(base) ~= 'table' then
		return empty
	end
	local slots: any = nil
	pcall(function()
		slots = slotServiceRef.SnapshotBaseSlots(base)
	end)
	if type(slots) ~= 'table' then
		return empty
	end
	local members: { any } = {}
	for _, slot in pairs(slots) do
		if type(slot) == 'table' then
			local state = slot.state or slot.State
			local kind = slot.occupantKind or slot.OccupantKind
			local occupantId = slot.occupantId or slot.OccupantId
			if
				state == SlotType.State.Occupied
				and kind == SlotType.OccupantKind.Animal
				and type(occupantId) == 'string'
			then
				local animal: any = nil
				pcall(function()
					animal = animalServiceRef.Get(occupantId)
				end)
				if
					type(animal) == 'table'
					and animal.ownerUserId == userId
					and animal.state == 'Slotted'
					and animal.slotId ~= nil
				then
					members[#members + 1] = {
						UniqueId = animal.uniqueId,
						DefinitionId = animal.definitionId,
						DisplayName = animal.displayName,
						Rarity = animal.rarity,
						Level = animal.Level or 1,
					}
				end
			end
		end
	end
	return { members = members, count = #members }
end

-- Authoritative ARENA team: animals in the player's OCCUPIED
-- ARENA slots only (normal AnimalStands never count).
-- Deterministic order: ascending arenaIndex (never
-- descendant order, never pairs() order — combat targeting
-- depends on it). Duplicate UniqueIds are rejected
-- defensively (one Animal = one combatant). Members snapshot
-- identity (UniqueId/DefinitionId/DisplayName/Rarity/Level)
-- plus Trait/Mutations for the combatant record; STATS are
-- never snapshotted here — BuildPlayerCombatant resolves
-- canonical stats from DefinitionId + Level at battle
-- creation, so mid-battle upgrades/sells/moves cannot
-- corrupt the fight. Fails safe to empty when the arena
-- runtime is not initialized. Never trusts client input.
-- Returns { members = {{ UniqueId, DefinitionId,
-- DisplayName, Rarity, Level, Trait, Mutations,
-- OwnerUserId, ArenaSlotId, ArenaIndex }}, count = n }.
function ArenaService.ResolveArenaTeam(userId: number): { [string]: any }
	local empty = { members = {}, count = 0 }
	if type(userId) ~= 'number' or not baseServiceRef or not animalServiceRef then
		return empty
	end
	local base: any = nil
	pcall(function()
		base = baseServiceRef.GetBaseByOwner(userId)
	end)
	if type(base) ~= 'table' or type(base.arenaSlots) ~= 'table' then
		return empty
	end
	local ordered: { any } = {}
	for _, slot in pairs(base.arenaSlots) do
		if type(slot) == 'table' then
			ordered[#ordered + 1] = slot
		end
	end
	table.sort(ordered, function(a: any, b: any)
		local ai = (type(a.arenaIndex) == 'number' and a.arenaIndex) or (a.index or 0)
		local bi = (type(b.arenaIndex) == 'number' and b.arenaIndex) or (b.index or 0)
		return ai < bi
	end)
	local members: { any } = {}
	local seen: { [string]: boolean } = {}
	for _, slot in ipairs(ordered) do
		if
			slot.state == SlotType.State.Occupied
			and slot.occupantKind == SlotType.OccupantKind.Animal
			and type(slot.occupantId) == 'string'
		then
			local animal: any = nil
			pcall(function()
				animal = animalServiceRef.Get(slot.occupantId)
			end)
			-- Mid-walk animals finish settling first: deploying
			-- one would abort its walk (unparented models trip
			-- the walker's Parent guard) and strand it off-slot
			-- on restore. A settled animal has controller == nil
			-- (cleared on arrival); any live controller means
			-- in-flight movement, so the slot sits this raid out.
			if
				type(animal) == 'table'
				and animal.ownerUserId == userId
				and animal.state == 'Slotted'
				and animal.slotId == slot.id
				and animal.stolenBy == nil
				and animal.carriedBy == nil
				and animal._mutex ~= true
				and animal.controller == nil
			then
				local uniqueId = animal.uniqueId
				if type(uniqueId) == 'string' and not seen[uniqueId] then
					seen[uniqueId] = true
					-- Snapshot identity only; combat stats are
					-- resolved canonically at battle creation.
					local trait: string? = nil
					if type(animal.Trait) == 'string' then
						trait = animal.Trait
					end
					local mutations: { string } = {}
					if type(animal.Mutations) == 'table' then
						for _, id in ipairs(animal.Mutations) do
							if type(id) == 'string' then
								mutations[#mutations + 1] = id
							end
						end
					end
					members[#members + 1] = {
						UniqueId = uniqueId,
						DefinitionId = animal.definitionId,
						DisplayName = animal.displayName,
						Rarity = animal.rarity,
						Level = animal.Level or 1,
						Trait = trait,
						Mutations = mutations,
						OwnerUserId = userId,
						ArenaSlotId = slot.id,
						ArenaIndex = slot.arenaIndex,
					}
				else
										Debug.Warn('ArenaSlots', ('team resolver skipped duplicate occupant id=%s on arena slot=%s'):format(
							tostring(slot.occupantId),
							tostring(slot.id)
						))
				end
			else
				warn(('[ArenaSlots] team resolver skipped invalid occupant on arena slot=%s'):format(tostring(slot.id)))
			end
		end
	end
	return { members = members, count = #members }
end

-- --- Battle area discovery -----------------------------------------------

-- Resolve the per-base battle area WITHOUT inventing world
-- coordinates: Base/Arena/{Center, PlayerSpawns,
-- EnemySpawns}. Missing markers are reported
-- (warn + state), never silently defaulted. Combat
-- requires ready == true (Center resolvable).
--
-- BossSpawn is deliberately NOT required and NOT checked
-- here: nothing spawns from it (bosses take EnemySpawns
-- slots; grep BossSpawn to verify). Requiring it would
-- force a redundant Studio object for zero runtime use.
function ArenaService.ResolveArenaArea(base: any): { [string]: any }
	local missing: { string } = {}
	local center: CFrame? = nil
	if type(base) ~= 'table' or typeof(base.folder) ~= 'Instance' then
		missing[#missing + 1] = 'base folder'
		return { ready = false, center = nil, missing = missing }
	end
	local area: Instance? = nil
	pcall(function()
		area = (base.folder :: Instance):FindFirstChild('Arena')
	end)
	if area == nil then
		missing[#missing + 1] = (base.folder :: Instance):GetFullName() .. '/Arena (folder)'
		warn(
			('[Arena] Battle area missing for base=%s: expected %s/Arena'):format(
				tostring(base.id),
				(base.folder :: Instance):GetFullName()
			)
		)
		return { ready = false, center = nil, missing = missing }
	end
	pcall(function()
		local node = (area :: Instance):FindFirstChild('Center')
		if node ~= nil then
			if node:IsA('BasePart') then
				center = node.CFrame
			elseif node:IsA('Attachment') then
				center = node.WorldCFrame
			else
				local okPivot, pivot = pcall(function()
					return (node :: PVInstance):GetPivot()
				end)
				if okPivot and typeof(pivot) == 'CFrame' then
					center = pivot
				end
			end
		end
	end)
	if center == nil then
		missing[#missing + 1] = 'Arena/Center'
	end
	for _, name in ipairs({ 'PlayerSpawns', 'EnemySpawns' }) do
		local present = false
		pcall(function()
			present = (area :: Instance):FindFirstChild(name) ~= nil
		end)
		if not present then
			missing[#missing + 1] = 'Arena/' .. name
		end
	end
	if #missing > 0 then
		warn(
			('[Arena] Battle area incomplete for base=%s missing=%s'):format(
				tostring(base.id),
				table.concat(missing, ', ')
			)
		)
		ArenaService.DebugArea(base)
	end
	return { ready = center ~= nil, center = center, missing = missing }
end

-- One-shot Arena hierarchy census for a base: what the
-- validator can ACTUALLY see (names, classes, full paths).
-- Runs only on validation failure (Start rejects) — never
-- per frame, never on success. Answers "I added Center, why
-- does the server say it's missing?" without guessing.
function ArenaService.DebugArea(base: any)
	pcall(function()
		if type(base) ~= 'table' or typeof(base.folder) ~= 'Instance' then
			Debug.Warn('AreaDebug', 'base has no folder')
			return
		end
		local folder = base.folder :: Instance
		local lines: { string } = {}
		lines[#lines + 1] = ('[Arena][AreaDebug] base=%s'):format(tostring(base.id))
		local area: Instance? = folder:FindFirstChild('Arena')
		if area == nil then
			lines[#lines + 1] = ('[Arena][AreaDebug] Arena = MISSING under %s'):format(folder:GetFullName())
			Debug.Warn('Arena', table.concat(lines, '\n'))
			return
		end
		lines[#lines + 1] = ('[Arena][AreaDebug] arenaPath=%s arenaClass=%s'):format(
			(area :: Instance):GetFullName(),
			(area :: Instance).ClassName
		)
		for _, child in ipairs((area :: Instance):GetChildren()) do
			lines[#lines + 1] = ('[Arena][AreaDebug] child name=%s class=%s'):format(child.Name, child.ClassName)
		end
		local center: Instance? = (area :: Instance):FindFirstChild('Center')
		if center == nil then
			lines[#lines + 1] = ('[Arena][AreaDebug] Center = MISSING (expected %s/Center)'):format(
				(area :: Instance):GetFullName()
			)
		else
			local usable = (center :: Instance):IsA('BasePart') or (center :: Instance):IsA('Attachment')
			if not usable then
				local okPivot = pcall(function()
					return ((center :: Instance) :: PVInstance):GetPivot()
				end)
				usable = okPivot
			end
			lines[#lines + 1] = ('[Arena][AreaDebug] Center path=%s class=%s usable=%s'):format(
				(center :: Instance):GetFullName(),
				(center :: Instance).ClassName,
				tostring(usable)
			)
		end
		for _, folderName in ipairs({ 'PlayerSpawns', 'EnemySpawns' }) do
			local spawns: Instance? = (area :: Instance):FindFirstChild(folderName)
			if spawns == nil then
				lines[#lines + 1] = ('[Arena][AreaDebug] %s = MISSING'):format(folderName)
			else
				local parts: { string } = {}
				for _, marker in ipairs((spawns :: Instance):GetChildren()) do
					parts[#parts + 1] = ('%s(%s)'):format(marker.Name, marker.ClassName)
				end
				lines[#lines + 1] = ('[Arena][AreaDebug] %s children: %s'):format(
					folderName,
					if #parts > 0 then table.concat(parts, ', ') else '(none)'
				)
			end
		end
		Debug.Warn('Arena', table.concat(lines, '\n'))
	end)
end

-- --- Session skeleton ------------------------------------------------------

function ArenaService.GetSession(userId: number): { [string]: any }?
	if type(userId) ~= 'number' then
		return nil
	end
	return sessions[userId]
end

-- Raid lock query for interaction services (sell / upgrade /
-- grab / steal). True when `uniqueId` is locked into ANY
-- active raid's immutable loadout. Pure scan over live
-- sessions (a handful at most); needs no injection because
-- raid sessions are module state. False for unknown ids and
-- when no raids are active — fail-open for non-raid play.
function ArenaService.IsAnimalRaidLocked(uniqueId: string): boolean
	if type(uniqueId) ~= 'string' or uniqueId == '' then
		return false
	end
	for _, session in pairs(sessions) do
		if type(session) == 'table' and type(session.team) == 'table' then
			for _, member in ipairs(session.team) do
				if type(member) == 'table' and member.UniqueId == uniqueId then
					return true
				end
			end
		end
	end
	return false
end

-- True while the user has a live (non-terminal) raid. Used
-- by UI gating and diagnostics; enforcement lives in the
-- start path (`already-active`) and per-animal locks above.
function ArenaService.HasActiveRaid(userId: number): boolean
	if type(userId) ~= 'number' then
		return false
	end
	local session = sessions[userId]
	return session ~= nil and (session.state == 'Active' or session.state == 'Transitioning')
end

-- Atomic raid-start validation. Every reject notifies
-- through the catalog (server owns the reason; the client
-- only shows state). Order: player -> services -> base ->
-- session -> carry/steal -> team. There is NO level gate:
-- every raid starts at its authorized stage (Buy3 = 1,
-- Buy1/Buy2 = server-resolved restart stages).
local function validateStart(player: Player, _arenaLevel: any): { [string]: any }
	if not Validation.LivePlayer(player) then
		return { ok = false, error = 'invalid-player' }
	end
	if not playerServiceRef or not baseServiceRef or not progressionServiceRef then
		warn('[Arena] Start rejected: services not wired')
		return { ok = false, error = 'service-not-ready' }
	end
	local userId = player.UserId
	local base: any = nil
	pcall(function()
		base = baseServiceRef.GetBaseByOwner(userId)
	end)
	if type(base) ~= 'table' then
		notifyWarning(player, 'Arena_NoBase', {})
		return { ok = false, error = 'no-base' }
	end
	if sessions[userId] ~= nil then
		notifyWarning(player, 'Arena_Active', {})
		return { ok = false, error = 'already-active' }
	end
	if carryRegistryRef then
		local carrying = false
		pcall(function()
			carrying = carryRegistryRef.IsCarrying(userId) == true
		end)
		if carrying then
			notifyWarning(player, 'Arena_Carrying', {})
			return { ok = false, error = 'carrying' }
		end
	end
	if stealServiceRef then
		local stealing = false
		pcall(function()
			stealing = stealServiceRef.IsStealCarry(userId) == true
		end)
		if stealing then
			notifyWarning(player, 'Arena_Stealing', {})
			return { ok = false, error = 'stealing' }
		end
	end
	local team = ArenaService.ResolveArenaTeam(userId)
	if team.count < ArenaConfig.MinTeamSize() then
		notifyWarning(player, 'Arena_NoTeam', {})
		warn(
			('[Arena] Start rejected: arena team %d < min %d player=%s'):format(
				team.count,
				ArenaConfig.MinTeamSize(),
				player.Name
			)
		)
		return { ok = false, error = 'no-team' }
	end
	return { ok = true, base = base, team = team }
end

function ArenaService.ValidateStart(player: Player, _arenaLevel: any): { [string]: any }
	local result = validateStart(player, nil)
	return { ok = result.ok == true, error = result.error }
end

-- Arena stand parking for the raid team. Deploy (true) hides
-- every deployed member's stand model so its ArenaAnimalStand
-- reads empty while the raid runs; restore (false) returns
-- each model to its exact prior container (same slot: slotId
-- never changes). Driven by the authoritative session team on
-- raid start/end only — never per stage, never polled.
-- Idempotent per animal (repeat calls no-op inside
-- AnimalService), and nil-safe when AnimalService is unwired
-- (headless tests). Declared before startStageBattle so raid
-- start can deploy inline.
-- Collector escrow: deployed animals' CashPools are parked
-- in the session for the run. There is NO central collector
-- pool: each animal record owns its CashPool (persisted) and
-- each stand collector merely mirrors its occupant's pool.
-- So "empty the collector" means: stash each deployed
-- animal's EXACT pool string in the session, zero the live
-- record (display republishes to $0 through the normal slot
-- path below), and freeze it there — deployed animals earn
-- nothing (IncomeService eligibility gate), offline earnings
-- use the same gate, and collection of $0 is a silent no-op.
-- The wallet NEVER increases: this is a park, not a claim.
-- Restore writes the stashed string back verbatim on every
-- terminal path (victory/defeat/cancel/silent-cancel/leave),
-- guarded exactly-once per session AND consume-on-restore
-- per animal, so duplicate cleanups can never double it.
local function snapshotMemberPool(session: { [string]: any }, uniqueId: string)
	if type(session.collectorEscrow) ~= 'table' then
		session.collectorEscrow = {}
	end
	local escrow = session.collectorEscrow
	if escrow[uniqueId] ~= nil then
		return
	end
	if not playerServiceRef or not playerServiceRef.GetPlayerData then
		return
	end
	local data: any = nil
	pcall(function()
		data = playerServiceRef.GetPlayerData(session.userId)
	end)
	local records = if type(data) == 'table' then data.Brainrots else nil
	if type(records) ~= 'table' then
		return
	end
	for _, record in ipairs(records) do
		if type(record) == 'table' and record.Id == uniqueId then
			local pool = if type(record.CashPool) == 'string' then record.CashPool else '0'
			escrow[uniqueId] = pool
			if pool ~= '0' then
				record.CashPool = '0'
			end
						Debug.Warn('ArenaCollector', ('escrow animal=%s pool=%s'):format(uniqueId, pool))
			return
		end
	end
end

local function restoreMemberPool(session: { [string]: any }, uniqueId: string)
	local escrow = session.collectorEscrow
	if type(escrow) ~= 'table' then
		return
	end
	local stashed = escrow[uniqueId]
	if type(stashed) ~= 'string' then
		return
	end
	-- Consume first: a second restore finds nothing.
	escrow[uniqueId] = nil
	if not playerServiceRef or not playerServiceRef.GetPlayerData then
		Debug.Warn('ArenaCollector', ('restore dropped animal=%s reason=no-profile-service'):format(uniqueId))
		return
	end
	local data: any = nil
	pcall(function()
		data = playerServiceRef.GetPlayerData(session.userId)
	end)
	local records = if type(data) == 'table' then data.Brainrots else nil
	if type(records) == 'table' then
		for _, record in ipairs(records) do
			if type(record) == 'table' and record.Id == uniqueId then
				record.CashPool = stashed
								Debug.Warn('ArenaCollector', ('restore animal=%s pool=%s'):format(uniqueId, stashed))
				return
			end
		end
	end
	Debug.Warn('ArenaCollector', ('restore skipped animal=%s reason=record-gone'):format(uniqueId))
end

local function setRaidDeployment(session: { [string]: any }, deployed: boolean)
	if type(session) ~= 'table' or type(session.team) ~= 'table' then
		return
	end
	local canPark = animalServiceRef and animalServiceRef.SetArenaDeployed
	local canRepaint = slotServiceRef and slotServiceRef.RefreshDisplays
	if not canPark and not canRepaint then
		return
	end
	if not deployed and session.collectorRestored == true then
				Debug.Warn('ArenaCollector', ('restore skipped runId=%s reason=already-restored'):format(tostring(session.sessionId)))
	else
		if not deployed then
			session.collectorRestored = true
		end
		for _, member in ipairs(session.team) do
			if type(member) == 'table' and type(member.UniqueId) == 'string' then
				if deployed then
					snapshotMemberPool(session, member.UniqueId)
				else
					restoreMemberPool(session, member.UniqueId)
				end
			end
		end
	end
	for _, member in ipairs(session.team) do
		if type(member) == 'table' and type(member.UniqueId) == 'string' then
			if canPark then
				pcall(animalServiceRef.SetArenaDeployed, member.UniqueId, deployed)
			end
			-- Stand menu + pool repaint through the canonical
			-- slot path: deployed stands lose the Upgrade
			-- affordance and read $0; restored stands regain
			-- both. Slot state itself never changes.
			if canRepaint and type(member.ArenaSlotId) == 'string' then
				pcall(slotServiceRef.RefreshDisplays, member.ArenaSlotId)
			end
		end
	end
end

-- Build + register + spawn the battle for the session's
-- CURRENT stage. Stage 1 builds fresh full-HP combatants;
-- later stages carry session.raidHP in (dead stay dead).
-- Synchronous, no timers: the win settlement calls this
-- inline, so there is no window for a stale stage to exist.
-- Returns true when the stage is live (session.state ==
-- 'Active'); false leaves the session for the caller to
-- terminate safely (no half-live stage, no reward).
local function startStageBattle(session: { [string]: any }, base: any?): boolean
	local userId = session.userId
	local stage = session.arenaLevel
	local levelDef = ArenaConfig.FindLevel(stage)
	if not levelDef then
		warn(
			('[ArenaRaid] STAGE_START refused user=%s session=%d reason=invalid-stage stage=%s'):format(
				tostring(userId),
				session.sessionId,
				tostring(stage)
			)
		)
		return false
	end
	if not battleServiceRef then
				Debug.Warn('ArenaRaid', ('STAGE_START refused user=%s session=%d reason=service-not-ready'):format(
				tostring(userId),
				session.sessionId
			))
		return false
	end
	-- Defensive: a previous battle object must never stay
	-- registered under this user (the tick unregisters
	-- finished battles before the end callback runs).
	pcall(battleServiceRef.UnregisterBattle, userId)
	-- Raid HP map for this stage: nil on stage 1 (fresh full
	-- HP by construction), carried values afterwards.
	local hpBySource: { [string]: number }? = nil
	if stage > 1 and type(session.raidHP) == 'table' then
		hpBySource = {}
		for id, hp in pairs(session.raidHP) do
			if type(id) == 'string' and type(hp) == 'number' then
				(hpBySource :: { [string]: number })[id] = hp
			end
		end
	end
	local battle, battleErr = battleServiceRef.CreateBattle(
		userId,
		session.sessionId,
		stage,
		session.team,
		levelDef.EnemyTeam,
		ArenaConfig.AttackCooldown(),
		os.clock(),
		session.stageGeneration,
		hpBySource
	)
	if battle == nil then
		warn(
			('[ArenaRaid] STAGE_START failed user=%s session=%d stage=%d: %s'):format(
				tostring(userId),
				session.sessionId,
				stage,
				tostring(battleErr)
			)
		)
		return false
	end
	session.battle = battle
	-- Models are presentation: headless/test sessions carry
	-- no base and run the sim model-free.
	if base ~= nil then
		local area = ArenaService.ResolveArenaArea(base)
		if not area.ready then
			session.battle = nil
			warn(
				('[ArenaRaid] STAGE_START refused user=%s session=%d stage=%d reason=area-not-ready missing=%s'):format(
					tostring(userId),
					session.sessionId,
					stage,
					table.concat(area.missing, ', ')
				)
			)
			return false
		end
		local positions = battleServiceRef.ResolveBattlePositions(base, #(battle.playerTeam or {}), #levelDef.EnemyTeam)
		if not positions.ready then
			session.battle = nil
						Debug.Warn('ArenaRaid', ('STAGE_START refused user=%s session=%d stage=%d reason=positions-not-ready'):format(
					tostring(userId),
					session.sessionId,
					stage
				))
			return false
		end
		local spawned = battleServiceRef.SpawnBattleModels(battle, base)
		if not spawned.ok then
			session.battle = nil
			warn(
				('[ArenaRaid] STAGE_START failed user=%s session=%d stage=%d: %s'):format(
					tostring(userId),
					session.sessionId,
					stage,
					tostring(spawned.error)
				)
			)
			return false
		end
	end
	battle.state = 'Active'
	session.state = 'Active'
	session.areaReady = true
	if not battleServiceRef.RegisterBattle(battle) then
		ArenaService.cleanupBattleModels(session)
		session.battle = nil
		warn(
			('[ArenaRaid] STAGE_START failed user=%s session=%d stage=%d reason=register-failed'):format(
				tostring(userId),
				session.sessionId,
				stage
			)
		)
		return false
	end
		Debug.Warn('ArenaRaid', ('STAGE_START user=%s session=%d stage=%d/%d gen=%d team=%d enemies=%d'):format(
			tostring(userId),
			session.sessionId,
			stage,
			(session.maxLevel or ArenaConfig.MaxLevel()),
			(session.stageGeneration or 0),
			tostring(#(battle.playerTeam or {})),
			tostring(#(battle.enemyTeam or {}))
		))
	return true
end

-- Restart option resolution (server-authoritative). The client
-- only names an option ('Buy1' | 'Buy2' | 'Buy3'); the server
-- determines the starting stage AND the price from the SAVED
-- LastLevel (highest level reached BEFORE the current run —
-- read live from progression per request, never the run's
-- temporary level) + ArenaConfig. Never trusts client
-- levels/prices. Returns { option, startLevel, price } or
-- { error }.
--   Buy3: free normal entry at stage 1 (always available).
--   Buy2: paid direct restart at LastLevel (needs >= 2).
--   Buy1: paid warmup restart at floor(LastLevel / 2)
--     (needs warmup > 1, i.e. LastLevel >= 4).
local function resolveRestartStart(userId: number, option: any): { [string]: any }
	local opt = if option == 'Buy1' or option == 'Buy2' or option == 'Buy3' then option else 'Buy3'
	if opt == 'Buy3' then
		return { option = 'Buy3', startLevel = 1, price = '0' }
	end
	local last = 0
	if progressionServiceRef then
		pcall(function()
			last = progressionServiceRef.GetLastReached(userId)
		end)
	end
	if opt == 'Buy2' then
		if not ArenaConfig.IsRestartAvailable(last, false) then
			return { error = 'restart-unavailable' }
		end
		return { option = 'Buy2', startLevel = ArenaConfig.RestartDirectLevel(last), price = ArenaConfig.RestartDirectPrice() }
	end
	-- Buy1.
	local warmup = ArenaConfig.RestartWarmupLevel(last)
	if not ArenaConfig.IsRestartAvailable(last, true) or warmup == nil then
		return { error = 'restart-unavailable' }
	end
	return { option = 'Buy1', startLevel = warmup, price = ArenaConfig.RestartWarmupPrice() }
end

-- Validated raid entry point. Creates the session atomically
-- only after EVERY check passes, locks the immutable
-- loadout snapshot, and starts at the authorized stage (1 for
-- Buy3, floor(LastLevel/2) for Buy1, LastLevel for Buy2 — all
-- server-resolved from SAVED progression). Any failure
-- rejects with NO session, NO reward, NO progress (a debit
-- that lands without a session is refunded before returning).
function ArenaService.StartArena(player: Player, option: any): { [string]: any }
	Debug.Log('Arena', 'raid request received, validating', {
		player = player.Name,
	})
	local checked = validateStart(player, nil)
	if not checked.ok then
		Debug.Log('Arena', 'raid request rejected', {
			player = player.Name,
			error = tostring(checked.error),
		})
		return { success = false, error = checked.error }
	end
	if not battleServiceRef then
		warn('[Arena] Start rejected: battle service not wired')
		return { success = false, error = 'service-not-ready' }
	end
	local userId = player.UserId
	local sessionId = nextSessionId
	nextSessionId += 1
	local members = (checked.team :: any).members
	-- Hard cap: arenas author exactly MaxTeamSize player
	-- markers. Keep the first N by ArenaIndex (resolver
	-- order) and say so loudly; never silently reorder.
	if #members > ArenaConfig.MaxTeamSize() then
				Debug.Warn('Arena', ('Team trimmed player=%s from %d to %d (arena supports %d combatants)'):format(
				player.Name,
				#members,
				ArenaConfig.MaxTeamSize(),
				ArenaConfig.MaxTeamSize()
			))
		local trimmed: { any } = {}
		for i = 1, ArenaConfig.MaxTeamSize() do
			trimmed[#trimmed + 1] = members[i]
		end
		members = trimmed
	end
	-- Fresh raid at the AUTHORIZED stage (1, warmup, or last
	-- reached): empty run HP (the first stage builds full-HP
	-- combatants by construction), no stage settled or rewarded.
	-- `team` is the locked immutable loadout snapshot for the
	-- whole run. The reward accumulator starts empty and settles
	-- exactly once at the terminal path — skipped stages are
	-- never credited. firstClearCursor snapshots history for
	-- contribution selection without touching persistence
	-- mid-raid.
	local restart = resolveRestartStart(userId, option)
	if restart.error ~= nil then
		notifyWarning(player, 'Arena_RestartUnavailable', {})
		ArenaService.PushState(player)
		return { success = false, error = restart.error }
	end
	local startLevel = restart.startLevel :: number
	local price = restart.price :: string
		Debug.Warn('ArenaStart', ('request option=%s validated player=%s startLevel=%d price=%s'):format(
			tostring(restart.option),
			player.Name,
			startLevel,
			tostring(price)
		))
	-- Paid restarts debit FIRST (atomic compare-and-debit: no
	-- charge on insufficient funds). The session is created
	-- synchronously below with no yields in between, and a
	-- post-debit session re-check closes the rapid double-fire
	-- race (second request refunds + rejects).
	local charged = false
	if price ~= '0' then
		local spent: any = nil
		if economyServiceRef then
			pcall(function()
				spent = economyServiceRef.TrySpendMoney(userId, price, TransactionReason.ArenaRestart)
			end)
		end
		if type(spent) ~= 'table' or spent.Success ~= true then
			notifyWarning(player, 'Arena_InsufficientFunds', {})
			ArenaService.PushState(player)
			return { success = false, error = 'insufficient-funds' }
		end
		charged = true
	end
	if sessions[userId] ~= nil then
		-- Lost the race: another request created the session
		-- after validation. Refund the debit, reject cleanly.
		if charged and economyServiceRef then
			pcall(economyServiceRef.AddMoney, userId, price, TransactionReason.ArenaRestartRefund)
		end
		notifyWarning(player, 'Arena_Active', {})
		ArenaService.PushState(player)
		return { success = false, error = 'already-active' }
	end
	sessions[userId] = {
		sessionId = sessionId,
		userId = userId,
		kind = 'Raid',
		arenaLevel = startLevel,
		maxLevel = ArenaConfig.MaxLevel(),
		stageGeneration = 1,
		state = 'Preparing',
		team = members,
		raidHP = {},
		raidAlive = {},
		-- Cumulative damage contribution for the whole run:
		-- {[animal UniqueId] = actual HP damage applied across
		-- all stages}. Carried per stage from the battle ledger
		-- (see carryBattleDamage); drives the proportional
		-- per-animal XP split at terminal settlement. Dead
		-- animals keep their earned share.
		damageDealt = {},
		-- Result keepsakes: {[animal UniqueId] = pristine clone
		-- of that participant's ACTUAL combat model
		-- (Workspace.ArenaBattles.Battle_<N>.Arena_Player<M>),
		-- captured before death-fade/advance/cleanup destroys
		-- the originals and parked in
		-- ReplicatedStorage.ArenaResultModels/Session_<N>}.
		-- Accumulated across stages via carryKeepsakes; the
		-- ArenaResult viewport clones THESE (client-side) — the
		-- single source of truth, never ServerStorage templates,
		-- never the stand model, never a placeholder.
		keepsakeModels = {},
		rewardedStages = {},
		settledStages = {},
		clearedStages = {},
		rewardAccum = { cash = '0', xp = 0 },
		rewardSettled = false,
		firstClearCursor = 1,
		areaReady = false,
		startedAt = os.clock(),
		battle = nil,
	}
	if progressionServiceRef then
		pcall(function()
			sessions[userId].firstClearCursor = progressionServiceRef.GetHighestCompleted(userId) + 1
		end)
	end
	lastRaid[userId] = nil
	local session = sessions[userId]
	-- Immutable participant snapshot is `session.team` (locked
	-- above). Log it once: this roster — in arena-slot order —
	-- is the single source of truth for result cards and XP
	-- shares, and it never shrinks as animals die.
		Debug.Warn('ArenaParticipants', ('session=%d count=%d'):format(sessionId, #members))
	for index, member in ipairs(members) do
		if type(member) == 'table' then
						Debug.Warn('ArenaParticipants', ('index=%d uid=%s name=%s defId=%s'):format(
					index,
					tostring(member.UniqueId),
					tostring(member.DisplayName),
					tostring(member.DefinitionId)
				))
		end
	end
	if not startStageBattle(session, checked.base) then
		sessions[userId] = nil
		if charged and economyServiceRef then
			pcall(economyServiceRef.AddMoney, userId, price, TransactionReason.ArenaRestartRefund)
		end
		notifyWarning(player, 'Arena_AreaNotReady', {})
		ArenaService.PushState(player)
		return { success = false, error = 'battle-failed' }
	end
	-- The raid is live: park the deployed team's stand models
	-- (stands read empty; battle clones carry the fight).
	setRaidDeployment(session, true)
	-- Hide ONLY this player's base Adv (after the purchase
	-- fully completed above — never before). Fully
	-- transparent, originals saved; every other base's Adv
	-- is untouched. Guarded: if the player left (or the
	-- session died) during the async battle start, hiding
	-- now would strand a record no terminal path restores.
	local liveSession = sessions[userId]
	local playerStillHere = false
	pcall(function()
		playerStillHere = Players:GetPlayerByUserId(userId) ~= nil
	end)
	if liveSession ~= nil and liveSession.sessionId == sessionId and playerStillHere then
		_hideAdv(userId, checked.base)
	end
		Debug.Warn('ArenaStart', ('session started player=%s session=%d option=%s startLevel=%d amount=%s'):format(
			player.Name,
			sessionId,
			tostring(restart.option),
			startLevel,
			tostring(price)
		))
		Debug.Warn('ArenaRaid', ('START user=%s session=%d team=%d maxStage=%d startLevel=%d'):format(
			player.Name,
			sessionId,
			#members,
			session.maxLevel,
			startLevel
		))
	notifySuccess(player, 'Arena_Started', { Level = startLevel })
	-- Tutorial guide layer observes the committed raid start
	-- (bus never throws; the start itself is unaffected).
	pcall(TutorialSignals.Fire, 'ArenaStarted', { UserId = userId })
	-- Funnel: raid live above (team deployed, battle started).
	pcall(function()
		local meta = { stage = startLevel }
		FunnelService:LogStep(player, 'Arena', 'ArenaStarted', meta)
		FunnelService:LogStep(player, 'Onboarding', 'FirstArenaStarted', nil)
	end)
	Debug.Log('AS', 'raid session created', {
		userId = tostring(userId),
		session = tostring(sessionId),
	})
	ArenaService.PushState(player)
	return { success = true, sessionId = sessionId, startLevel = startLevel, option = restart.option }
end

-- Canonical raid-start alias. The remote ingress maps both
-- 'Start' (legacy name) and 'StartRaid' here: one
-- authoritative path (legacy callers default to Buy3).
function ArenaService.StartRaid(player: Player): { [string]: any }
	return ArenaService.StartArena(player, 'Buy3')
end

-- Presentation window for the final impact bundle: terminal
-- paths keep battle models alive briefly so the killing
-- blow's flash/reaction/death-fade (and the client FX bundle)
-- complete instead of vanishing in the same tick as the
-- settle. Mid-raid stage advances still destroy immediately
-- (the next stage spawns synchronously into a fresh folder).
local TERMINAL_CLEANUP_DELAY = 1.2

-- Idempotent battle-model teardown for one session (called
-- from settle, cancel, and leave paths alike). With
-- `delaySec`, destruction is deferred but captured to THIS
-- battle only: a later raid's folder/models are never
-- touched (unregister already stopped the ticks; this is
-- purely the visual window).
function ArenaService.cleanupBattleModels(session: { [string]: any }?, delaySec: number?)
	if type(session) ~= 'table' then
		return
	end
	if not battleServiceRef then
		return
	end
	local delay = tonumber(delaySec) or 0
	if delay ~= delay or delay <= 0 then
		pcall(battleServiceRef.DestroyBattleModels, session.battle)
		return
	end
	if delay > ArenaPresentationConfig.Combat.ModelCleanupMaxDelay then
		delay = ArenaPresentationConfig.Combat.ModelCleanupMaxDelay
	end
	local battle = session.battle
	task.delay(delay, function()
		pcall(function()
			if battleServiceRef then
				battleServiceRef.DestroyBattleModels(battle)
			end
		end)
	end)
end

local function pushResult(player: Player, action: string, success: boolean, err: string?, extra: any?)
	local payload: { [string]: any } = {
		Action = action,
		Success = success,
		Error = err,
	}
	if type(extra) == 'table' then
		for k, v in pairs(extra) do
			payload[k] = v
		end
	end
	pcall(Remotes.FireClient, player, Remotes.Names.ArenaResult, payload)
end

-- Forward declaration: the terminal settler is defined
-- below (next to the accumulator), but retreat needs it
-- here. Assigned exactly once at its definition site.
local settleRaidReward: any = nil

-- Player-requested retreat: ends the raid at its current
-- stage. Settlement is progressive (same as defeat): cleared
-- stages pay, the unplayed remainder forfeits. Persistent
-- animals are untouched.
function ArenaService.CancelArena(player: Player): { [string]: any }
	if not Validation.LivePlayer(player) then
		return { success = false, error = 'invalid-player' }
	end
	local userId = player.UserId
	local session = sessions[userId]
	if session == nil then
		return { success = false, error = 'no-session' }
	end
	session.state = 'Cleaned'
	-- Retreat stays silent (no completion toast): withdrawing
	-- is not a completion. Only battle-decided terminals toast.
	local retreatSettle = settleRaidReward(userId, session, false, true)
	-- Retreat restores the team to its Arena stands (same
	-- slots; settled rewards already committed above).
	setRaidDeployment(session, false)
	-- Retreat ends the run: Adv visibility restores too.
	_restoreAdv(userId)
	ArenaService.cleanupBattleModels(session, TERMINAL_CLEANUP_DELAY)
	sessions[userId] = nil
	if battleServiceRef then
		pcall(battleServiceRef.UnregisterBattle, userId)
	end
	local retreatCash = '0'
	local retreatXP = 0
	if type(retreatSettle) == 'table' then
		if type(retreatSettle.cash) == 'string' then
			retreatCash = retreatSettle.cash
		end
		if tonumber(retreatSettle.xp) then
			retreatXP = tonumber(retreatSettle.xp) or 0
		end
	end
	lastRaid[userId] = {
		RaidComplete = false,
		Retreated = true,
		Stage = session.arenaLevel,
		MaxStage = session.maxLevel,
		SessionId = session.sessionId,
		EarnedCash = retreatCash,
		EarnedXP = retreatXP,
	}
		Debug.Warn('ArenaRaid', ('RETREAT user=%s session=%d at stage=%d'):format(
			player.Name,
			tostring(session.sessionId),
			session.arenaLevel
		))
	pushResult(player, 'Cancel', true, nil, {
		RaidComplete = false,
		Stage = session.arenaLevel,
		MaxStage = session.maxLevel,
	})
	ArenaService.PushState(player)
	-- Tutorial guide layer observes the retreat so it can
	-- return a mid-arena tutorial to StartArena (recoverable,
	-- never stuck). Bus never throws.
	pcall(TutorialSignals.Fire, 'ArenaCancelled', { UserId = userId })
	return { success = true }
end

-- Silent battle cancel (validator trip: leave, base loss,
-- destroyed models). No reward, no stage settlement, no
-- toast — just teardown + state refresh when the player is
-- still around. `stageGen` must match the session's current
-- generation (nil-tolerant only for gen-less legacy/test
-- sessions); a stale cancel is a silent no-op.
function ArenaService.CancelBattleSilent(userId: number, sessionId: number, stageGen: number?)
	if type(userId) ~= 'number' or type(sessionId) ~= 'number' then
		return
	end
	local session = sessions[userId]
	if session == nil or session.sessionId ~= sessionId or session.state ~= 'Active' then
		return
	end
	if session.stageGeneration ~= stageGen then
		return
	end
	session.state = 'Cleaned'
	-- Validator-trip cancel: no settlement by design, but the
	-- team still returns to its Arena stands.
	setRaidDeployment(session, false)
	-- Unexpected end still restores Adv (never stranded hidden).
	_restoreAdv(userId)
	ArenaService.cleanupBattleModels(session, TERMINAL_CLEANUP_DELAY)
	sessions[userId] = nil
	if battleServiceRef then
		pcall(battleServiceRef.UnregisterBattle, userId)
	end
		Debug.Warn('ArenaRaid', ('CANCEL user=%s session=%d stage=%d (no rewards)'):format(
			tostring(userId),
			sessionId,
			session.arenaLevel
		))
	local player: Player? = nil
	pcall(function()
		player = Players:GetPlayerByUserId(userId)
	end)
	if player then
		ArenaService.PushState(player)
	end
end

function ArenaService.OpenArena(player: Player)
	if not Validation.LivePlayer(player) then
		return
	end
	Debug.Log('Arena', 'Adventurer interacted; opening raid menu', { player = player.Name })
	ArenaService.PushState(player, true)
	if progressionServiceRef then
		-- Historical best (highest stage ever reached). NOT a
		-- gate: a normal raid starts at stage 1; paid restarts
		-- start at the authorized warmup/last stage.
		local best = 0
		pcall(function()
			best = progressionServiceRef.GetHighestCompleted(player.UserId)
		end)
		Debug.Log('Arena', 'raid menu generated', {
			player = player.Name,
			bestStage = tostring(best),
			maxStage = tostring(ArenaConfig.MaxLevel()),
		})
	end
end

function ArenaService.ForgetPlayer(userId: number)
	if type(userId) ~= 'number' then
		return
	end
	if sessions[userId] ~= nil then
				Debug.Warn('ArenaRaid', ('LEAVE user=%s session=%s stage=%d (raid terminated, no further rewards)'):format(
				tostring(userId),
				tostring(sessions[userId].sessionId),
				sessions[userId].arenaLevel
			))
		-- Record-gone safe: AnimalService drops parked entries
		-- whose records are already destroyed (leave sweep runs
		-- first in bootstrap), so this can never strand state.
		setRaidDeployment(sessions[userId], false)
		-- Leave mid-raid: Adv restores if its parts still exist
		-- (destroyed parts skip silently).
		_restoreAdv(userId)
		ArenaService.cleanupBattleModels(sessions[userId], TERMINAL_CLEANUP_DELAY)
		sessions[userId] = nil
	end
	lastRaid[userId] = nil
	if battleServiceRef then
		pcall(battleServiceRef.UnregisterBattle, userId)
	end
	-- Tutorial guide layer observes the leave-teardown like a
	-- retreat (recoverable, never stuck). Bus never throws.
	pcall(TutorialSignals.Fire, 'ArenaCancelled', { UserId = userId })
	Debug.Log('AS', 'ForgetPlayer: raid session cleared', { userId = tostring(userId) })
end

-- Copy run HP out of the finished battle into the
-- session. Persistent animals are NEVER touched: raid HP
-- lives only here (and in the next stage's combatants).
-- Dead (0 HP / Alive == false) stays dead for the run.
local function snapshotRaidHP(session: { [string]: any })
	local battle = session.battle
	if type(battle) ~= 'table' or type(battle.playerTeam) ~= 'table' then
		return
	end
	if type(session.raidHP) ~= 'table' then
		session.raidHP = {}
	end
	if type(session.raidAlive) ~= 'table' then
		session.raidAlive = {}
	end
	for _, c in ipairs(battle.playerTeam) do
		if type(c) == 'table' and type(c.SourceAnimalId) == 'string' then
			local hp = tonumber(c.CurrentHealth) or 0
			if hp ~= hp or hp < 0 then
				hp = 0
			end
			session.raidHP[c.SourceAnimalId] = hp
			session.raidAlive[c.SourceAnimalId] = c.Alive == true and hp > 0
		end
	end
end

-- Carry this stage's damage ledger into the raid session.
-- Called once per settled stage (win AND loss paths) before
-- any advance/terminate decision, so the final stage's damage
-- is never lost. Consumes the battle ledger (resets it) so a
-- repeated carry can never double-count.
local function carryBattleDamage(session: { [string]: any })
	local battle = session.battle
	if type(battle) ~= 'table' or type(battle.damageBySource) ~= 'table' then
		return
	end
	if type(session.damageDealt) ~= 'table' then
		session.damageDealt = {}
	end
	for id, amt in pairs(battle.damageBySource) do
		if type(id) == 'string' and type(amt) == 'number' and amt > 0 then
			session.damageDealt[id] = (tonumber(session.damageDealt[id]) or 0) + amt
		end
	end
	battle.damageBySource = {}
end

-- Carry this stage's result keepsakes into the raid session.
-- Captures survivors' live combat models FIRST (they are still
-- parented: advance/terminal cleanup runs after this), then
-- drains the battle store (which already holds death-time
-- captures for animals that died this stage). Merged by
-- persistent SourceAnimalId, so a wiped 3-animal team still
-- holds 3 distinct combat clones at raid end. Nil-safe: stages
-- with no models contribute nothing.
local function carryKeepsakes(session: { [string]: any })
	if not battleServiceRef then
		return
	end
	pcall(battleServiceRef.CaptureLiveKeepsakes, session.battle)
	if type(session.keepsakeModels) ~= 'table' then
		session.keepsakeModels = {}
	end
	local taken: { [string]: any } = {}
	pcall(function()
		taken = battleServiceRef.TakeKeepsakes(session.battle)
	end)
	if type(taken) == 'table' then
		for uid, clone in pairs(taken) do
			if type(uid) == 'string' and typeof(clone) == 'Instance' and (clone :: Instance).Parent ~= nil then
				session.keepsakeModels[uid] = clone
			end
		end
	end
end

-- Stage contribution (NOT a payout). A cleared stage adds
-- its configured reward to the raid's internal accumulator
-- only: no EconomyService call, no Arena XP grant, no
-- balance change, no reward toast. The accumulator is
-- temporary run state settled exactly once on the terminal
-- path (settleRaidReward below). First/repeat selection
-- uses the raid's first-clear cursor (snapshotted from
-- HighestCompleted at raid start, advanced per contributed
-- first-clear), so mid-raid persistence is never touched.
-- Idempotent per (session, stage): repeats contribute
-- nothing. Called only after the settle gates in
-- CompleteBattle (sessionId + generation + unsettled stage).
local function accumulateStageReward(session: { [string]: any }, stage: number): { [string]: any }
	local userId = session.userId
	local sessionId = session.sessionId
	if type(session.rewardedStages) ~= 'table' then
		session.rewardedStages = {}
	end
	if session.rewardedStages[stage] == true then
				Debug.Warn('ArenaRaid', ('Accumulator SKIPPED user=%s session=%d stage=%d reason=already-accumulated'):format(
				tostring(userId),
				sessionId,
				stage
			))
		return { ok = false, error = 'already-accumulated' }
	end
	session.rewardedStages[stage] = true
	local arenaLevel = stage
	local levelDef = ArenaConfig.FindLevel(arenaLevel)
	local firstClear = false
	local cash = '0'
	local xp = 0
	if levelDef then
		xp = levelDef.Rewards.ArenaXP
		-- First-clear cursor: stage N contributes the
		-- first-clear bounty exactly when it is the next
		-- expected new stage. Raid stages clear in ascending
		-- order, so this reproduces the RecordLevelWin chain
		-- without touching persistence mid-raid.
		local cursor = tonumber(session.firstClearCursor) or 1
		if arenaLevel == cursor then
			firstClear = true
			session.firstClearCursor = cursor + 1
		end
		cash = if firstClear then levelDef.Rewards.FirstClearCash else levelDef.Rewards.RepeatCash
		if type(session.rewardAccum) ~= 'table' then
			session.rewardAccum = { cash = '0', xp = 0 }
		end
		local accum = session.rewardAccum
		if type(xp) == 'number' and xp > 0 then
			accum.xp = (tonumber(accum.xp) or 0) + xp
		end
		if type(cash) == 'string' and cash ~= '' then
			local okAdd, total = pcall(BigNumber.Add, accum.cash or '0', cash)
			if okAdd and type(total) == 'string' then
				accum.cash = total
			end
		end
		if type(session.clearedStages) ~= 'table' then
			session.clearedStages = {}
		end
		session.clearedStages[#session.clearedStages + 1] = stage
				Debug.Warn('ArenaRaid', ('STAGE_REWARD_ACCUMULATED user=%s session=%d stage=%d firstClear=%s cashAdded=%s xpAdded=%d totalCash=%s totalXP=%d'):format(
				tostring(userId),
				sessionId,
				arenaLevel,
				tostring(firstClear),
				tostring(cash),
				xp,
				tostring(accum.cash),
				tonumber(accum.xp) or 0
			))
				Debug.Warn('ArenaReward', ('WaveCompleted runId=%s wave=%d cashAdded=%s xpAdded=%d totalCash=%s totalXP=%d'):format(
				tostring(sessionId),
				arenaLevel,
				tostring(cash),
				xp,
				tostring(accum.cash),
				tonumber(accum.xp) or 0
			))
	end
	return { ok = true, firstClear = firstClear, cash = cash, xp = xp }
end
-- Terminal raid settlement — the ONLY economy/XP payout
-- in the Arena. Freezes the accumulator, then records stage
-- history for every cleared stage, performs ONE
-- EconomyService transaction, and grants Arena XP ONCE.
--
-- POLICY (progressive, explicit): a raid pays the accumulated
-- rewards of every SUCCESSFULLY CLEARED stage, whether the run
-- ends in full completion or in defeat. A wipe on stage N pays
-- stages 1..N-1; the failed stage contributes nothing (its
-- reward is only added on actual wave completion). An empty
-- accumulator (wipe before clearing anything) settles $0 / 0 XP.
-- Leave / silent-cancel paths never reach settlement (abandoned
-- runs forfeit) — only battle-decided terminals settle.
--
-- Idempotent per session: the first call settles, repeats
-- no-op. Preferred order: freeze -> history -> cash -> XP
-- -> mark -> toast. The completion toast fires only after the
-- cash transaction succeeds (never before, never '+$0').
settleRaidReward = function(
	userId: number,
	session: { [string]: any },
	completed: boolean,
	suppressToast: boolean?
): { [string]: any }
	if session.rewardSettled == true then
				Debug.Warn('ArenaRaid', ('REWARD_SETTLEMENT_SKIPPED user=%s session=%d reason=already-settled'):format(
				tostring(userId),
				session.sessionId
			))
				Debug.Warn('ArenaReward', ('SettlementSkipped runId=%s reason=AlreadySettled'):format(tostring(session.sessionId)))
		return { ok = false, error = 'already-settled' }
	end
	session.rewardSettled = true
	local accum = session.rewardAccum
	if type(accum) ~= 'table' then
		accum = { cash = '0', xp = 0 }
	end
	local totalCash = if type(accum.cash) == 'string' then accum.cash else '0'
	local totalXP = tonumber(accum.xp) or 0
		Debug.Warn('ArenaRaid', ('REWARD_SETTLEMENT_START user=%s session=%d completed=%s cash=%s xp=%d'):format(
			tostring(userId),
			session.sessionId,
			tostring(completed),
			tostring(totalCash),
			totalXP
		))
	local clearedCount = 0
	if type(session.clearedStages) == 'table' then
		clearedCount = #session.clearedStages
	end
	if not completed then
				Debug.Warn('ArenaReward', ('DefeatSettlement runId=%s currentWave=%s highestClearedWave=%d cash=%s xp=%d'):format(
				tostring(session.sessionId),
				tostring(session.arenaLevel),
				clearedCount,
				tostring(totalCash),
				totalXP
			))
	end
	if totalCash == '0' and totalXP <= 0 then
				Debug.Warn('ArenaRaid', ('REWARD_EMPTY user=%s session=%d completed=%s (nothing cleared, no payout)'):format(
				tostring(userId),
				session.sessionId,
				tostring(completed)
			))
		return { ok = true, paid = false, cash = '0', xp = 0 }
	end
	local player: Player? = nil
	pcall(function()
		player = Players:GetPlayerByUserId(userId)
	end)
	-- History first: one RecordLevelWin per cleared stage, in
	-- ascending order, so Wins and HighestCompleted reflect
	-- the settled run through the single authority.
	if progressionServiceRef and progressionServiceRef.RecordLevelWin and type(session.clearedStages) == 'table' then
		local ordered: { number } = {}
		for _, stage in ipairs(session.clearedStages) do
			if type(stage) == 'number' then
				ordered[#ordered + 1] = stage
			end
		end
		table.sort(ordered)
		for _, stage in ipairs(ordered) do
			pcall(progressionServiceRef.RecordLevelWin, userId, stage)
		end
	end
	-- ONE economy transaction for the whole raid.
	local settledCash: string? = nil
	local settledNewMoney: string? = nil
	local oldMoney: string? = nil
	if economyServiceRef and type(totalCash) == 'string' then
		local saneCash: string? = nil
		pcall(function()
			saneCash = BigNumber.sanitize(totalCash)
		end)
		if saneCash == nil or saneCash == '0' then
			warn(
				('[ArenaRaid] REWARD grant SKIPPED user=%s session=%d reason=invalid-cash raw=%s'):format(
					tostring(userId),
					session.sessionId,
					tostring(totalCash)
				)
			)
		else
			pcall(function()
				if economyServiceRef.GetMoney then
					oldMoney = economyServiceRef.GetMoney(userId)
				end
			end)
			local grantOk, result =
				pcall(economyServiceRef.AddMoney, userId, saneCash, 'ArenaReward', { ApplyMultiplier = false })
			if not grantOk or type(result) ~= 'table' or result.Success ~= true then
				warn(
					('[ArenaRaid] REWARD grant failed user=%s session=%d amount=%s (settled once, no retry)'):format(
						tostring(userId),
						session.sessionId,
						tostring(saneCash)
					)
				)
			else
				settledCash = saneCash
				if type(result.NewMoney) == 'string' then
					settledNewMoney = result.NewMoney
				end
								Debug.Warn('ARENA_REWARD', ('userId=%s session=%d cash=%s oldMoney=%s newMoney=%s tx=%s'):format(
						tostring(userId),
						tostring(session.sessionId),
						tostring(saneCash),
						tostring(oldMoney),
						tostring(settledNewMoney),
						tostring(result.TransactionId)
					))
				-- Canonical money sync (CashCollected + state
				-- push), winner ONLY, per-session player.
				if player then
					pcall(function()
						Remotes.FireClient(player, Remotes.Names.CashCollected, {
							Amount = saneCash,
							NewMoney = settledNewMoney,
						})
					end)
										Debug.Warn('MONEY_SYNC', ('userId=%s remote=CashCollected value=%s'):format(
							tostring(userId),
							tostring(settledNewMoney)
						))
					pcall(function()
						if playerServiceRef and playerServiceRef.PushState then
							local snap = nil
							if baseServiceRef and baseServiceRef.Snapshot then
								local okSnap, s = pcall(baseServiceRef.Snapshot, userId)
								if okSnap then
									snap = s
								end
							end
							playerServiceRef.PushState(player, snap)
						end
					end)
				end
			end
		end
	end
	-- Arena XP ONCE for the whole raid.
	if progressionServiceRef and totalXP > 0 then
		progressionServiceRef.AddArenaXP(userId, totalXP)
				Debug.Warn('ArenaRaid', ('XP settled user=%s session=%d amount=%d'):format(tostring(userId), session.sessionId, totalXP))
	end
		Debug.Warn('ArenaRaid', ('REWARD_SETTLEMENT_SUCCESS user=%s session=%d cash=%s xp=%d'):format(
			tostring(userId),
			session.sessionId,
			tostring(settledCash or '0'),
			totalXP
		))
	if player and settledCash ~= nil and suppressToast ~= true then
		-- NOTE: Amount is the RAW BigNumber decimal string.
		-- NotificationService owns formatting; a preformatted
		-- value would sanitize to a '$0' toast.
		-- The completion toast fires once on every PAID terminal
		-- settlement — full victory AND progressive defeat
		-- payouts alike. A wipe is a successful Arena completion
		-- for progression purposes, so it plays the Success SFX
		-- (Arena_RaidComplete), never the RaidFailed warning.
		-- Unpaid ($0/empty) settlements stay silent — never '+$0'.
		notifySuccess(player, 'Arena_RaidComplete', { Amount = settledCash })
	end
	return {
		ok = true,
		paid = settledCash ~= nil,
		cash = settledCash or '0',
		xp = totalXP,
		oldMoney = oldMoney,
		newMoney = settledNewMoney,
	}
end

-- End-of-raid result rows for the ArenaResult screen. Pure given
-- its inputs (headless-testable): snapshots presentation data from
-- the battle combatants + authoritative animal records. Never
-- touches Workspace, never grants anything, never trusts the client.
--
-- Levels/XP are record values at snapshot time. Victorious raids
-- grant each participating animal settled-raid-XP x
-- AnimalXPMultiplier via AnimalService:AddXP; the extras param
-- carries those committed results (PreLevels pins pre-grant
-- levels, Awards carries {LevelAfter, XPAwarded}).
-- CombatModel is the ONLY viewport source: the pristine
-- pre-destruction clone of the participant's ACTUAL combat model
-- (ReplicatedStorage.ArenaResultModels/Session_<id>), captured
-- before death-fade/cleanup. Nil when no keepsake survived — the
-- client logs an error and leaves that viewport empty (never a
-- stand-model fallback, never a template, never a placeholder).
-- Text still renders from this snapshot. Capped at
-- RESULT_CARD_CAP, the UI's card capacity.
local RESULT_CARD_CAP = ArenaConfig.ResultCardCap

local function buildResultAnimals(combatants: any, getAnimal: any, extras: { [string]: any }?): { { [string]: any } }
	local rows: { { [string]: any } } = {}
	if type(combatants) ~= 'table' then
		return rows
	end
	local preLevels: { [string]: number }? = nil
	local preXP: { [string]: number }? = nil
	local awards: { [string]: any }? = nil
	local damageMap: { [string]: number }? = nil
	local damageShare: { [string]: number }? = nil
	-- Captured combat-model keepsakes ({[UniqueId] = pristine
	-- pre-destruction clone of the participant's ACTUAL combat
	-- model}). The viewport clones THESE, never templates.
	local combatModels: { [string]: any }? = nil
	if type(extras) == 'table' then
		if type(extras.PreLevels) == 'table' then
			preLevels = extras.PreLevels
		end
		if type(extras.PreXP) == 'table' then
			preXP = extras.PreXP
		end
		if type(extras.Awards) == 'table' then
			awards = extras.Awards
		end
		-- Authoritative per-animal damage contribution (actual HP
		-- applied during the run) + fractional share of the team
		-- total. Server-computed only; the client renders XP from
		-- the committed grant and never recomputes shares.
		if type(extras.Damage) == 'table' then
			damageMap = extras.Damage
		end
		if type(extras.DamageShare) == 'table' then
			damageShare = extras.DamageShare
		end
		-- Captured combat-model keepsakes ({[UniqueId] = pristine
		-- pre-destruction clone of the participant's ACTUAL combat
		-- model}). The viewport clones THESE, never templates.
		if type(extras.CombatModels) == 'table' then
			combatModels = extras.CombatModels
		end
	end
	for _, c in ipairs(combatants) do
		if #rows >= RESULT_CARD_CAP then
			break
		end
		if type(c) == 'table' then
			local uniqueId = if type(c.SourceAnimalId) == 'string' then c.SourceAnimalId else nil
			local record: any = nil
			if uniqueId ~= nil and type(getAnimal) == 'function' then
				pcall(function()
					record = getAnimal(uniqueId)
				end)
			end
			if type(record) ~= 'table' then
				record = {}
			end
			local displayName = if type(record.displayName) == 'string' and record.displayName ~= ''
				then record.displayName
				else (if type(c.DisplayName) == 'string' and c.DisplayName ~= '' then c.DisplayName else 'Animal')
			local rarity = if type(record.rarity) == 'string' and record.rarity ~= ''
				then record.rarity
				else (if type(c.Rarity) == 'string' then c.Rarity else '?')
			local level = tonumber(record.Level) or tonumber(c.Level) or 1
			if level ~= level or level < 1 then
				level = 1
			end
			level = math.floor(level)
			-- LevelBefore prefers the pre-grant snapshot (records may
			-- already reflect grants when extras are supplied).
			if preLevels ~= nil and type(uniqueId) == 'string' then
				local pre = tonumber((preLevels :: { [string]: number })[uniqueId])
				if pre ~= nil and pre == pre and pre >= 1 then
					level = math.floor(pre)
				end
			end
			-- XP/LevelAfter come ONLY from committed grants (extras).
			-- Without a grant record the honest values are 0 awarded
			-- and no level change — never the record total, never
			-- fabricated. XPBefore prefers the pre-grant snapshot.
			local levelAfter = level
			local xpAwarded = 0
			local xpBefore: number? = nil
			if preXP ~= nil and type(uniqueId) == 'string' then
				local pre = tonumber((preXP :: { [string]: number })[uniqueId])
				if pre ~= nil and pre == pre and pre >= 0 then
					xpBefore = math.floor(pre)
				end
			end
			local xpAfter: number? = nil
			if awards ~= nil and type(uniqueId) == 'string' then
				local award = (awards :: { [string]: any })[uniqueId]
				if type(award) == 'table' then
					local la = tonumber(award.LevelAfter)
					if la ~= nil and la == la and la >= 1 then
						levelAfter = math.floor(la)
					end
					local xa = tonumber(award.XPAwarded)
					if xa ~= nil and xa == xa and xa >= 0 then
						xpAwarded = math.floor(xa)
					end
					local xafter = tonumber(award.XPAfter)
					if xafter ~= nil and xafter == xafter and xafter >= 0 then
						xpAfter = math.floor(xafter)
					end
				end
			end
			if xpBefore == nil then
				local recXP = tonumber(record.XP) or 0
				if recXP ~= recXP or recXP < 0 then
					recXP = 0
				end
				xpBefore = math.floor(recXP)
			end
			if xpAfter == nil then
				xpAfter = xpBefore
			end
			local trait: string? = nil
			if type(record.Trait) == 'string' and record.Trait ~= '' then
				trait = record.Trait
			end
			local mutations: { string } = {}
			if type(record.Mutations) == 'table' then
				for _, id in ipairs(record.Mutations) do
					if type(id) == 'string' and id ~= '' then
						mutations[#mutations + 1] = id
					end
				end
			end
			local definitionId = if type(record.definitionId) == 'string'
				then record.definitionId
				else (if type(c.DefinitionId) == 'string' then c.DefinitionId else nil)
			-- Keepsake proof: the viewport clones THIS exact instance
			-- (the actual combat-model clone — never the stand model,
			-- never a ServerStorage template). A missing keepsake is
			-- an ERROR, never a silent fallback: the card renders
			-- text-only and the log names the participant.
			local keepsake: Instance? = nil
			if combatModels ~= nil and type(uniqueId) == 'string' then
				local candidate = (combatModels :: { [string]: any })[uniqueId]
				if typeof(candidate) == 'Instance' and (candidate :: Instance):IsA('Model') then
					keepsake = candidate
				end
			end
			if uniqueId ~= nil then
				if keepsake ~= nil then
					pcall(function()
												Debug.Warn('ArenaResultViewport', ('uid=%s sourceArenaModel=%s sourceClass=%s'):format(
								tostring(uniqueId),
								(keepsake :: Instance):GetFullName(),
								(keepsake :: Instance).ClassName
							))
					end)
				else
					warn(
						('[ArenaResultModel] ERROR missing live combat model session-keepsake uid=%s (viewport will stay empty)'):format(
							tostring(uniqueId)
						)
					)
				end
			end
			local damageDealt = 0
			if damageMap ~= nil and type(uniqueId) == 'string' then
				local d = tonumber((damageMap :: { [string]: number })[uniqueId])
				if d ~= nil and d == d and d > 0 then
					damageDealt = d
				end
			end
			local share = 0
			if damageShare ~= nil and type(uniqueId) == 'string' then
				local s = tonumber((damageShare :: { [string]: number })[uniqueId])
				if s ~= nil and s == s and s >= 0 and s <= 1 then
					share = s
				end
			end
			rows[#rows + 1] = {
				UniqueId = uniqueId,
				DefinitionId = definitionId,
				DisplayName = displayName,
				Rarity = rarity,
				Trait = trait,
				Mutations = mutations,
				LevelBefore = level,
				LevelAfter = levelAfter,
				XP = xpAwarded,
				XPBefore = xpBefore,
				XPAfter = xpAfter,
				Alive = c.Alive == true,
				CombatModel = keepsake,
				Damage = damageDealt,
				DamagePercent = share,
			}
		end
	end
	return rows
end

-- Terminal raid teardown shared by complete / fail /
-- transition-failure paths. Settles the accumulated reward
-- exactly once FIRST (progressive: cleared stages pay on both
-- victory and defeat), then destroys models, unregisters the
-- battle, clears the session, records the outcome for the
-- results UI, and notifies the client (RaidEnd result + fresh
-- state). Guarded by raidFinalized: exactly one terminal path
-- may finalize a session (victory/defeat racing, duplicate
-- events, retreat races) — first call wins, repeats no-op.
local function terminateRaid(userId: number, session: { [string]: any }, outcome: { [string]: any })
	-- Duplicate-completion guard: exactly one terminal path may
	-- finalize a session (victory/defeat handlers racing, duplicate
	-- events, retreat races). First call wins; repeats no-op.
	if session.raidFinalized == true then
				Debug.Warn('ArenaRaid', ('TERMINATE_SKIPPED user=%s session=%d reason=already-finalized'):format(
				tostring(userId),
				session.sessionId
			))
		return
	end
	session.raidFinalized = true
	local completed = outcome.RaidComplete == true
	-- LastReached: the highest stage actually reached in this
	-- terminal raid (victory final stage, defeat failed stage,
	-- mutual wipe included). Max semantics in the progression
	-- service: a shorter later run never erases it. Retreats
	-- never pass through here, so withdrawing records nothing.
	-- Starting stage != reached stage: buying a restart does not
	-- move this, only terminal raid ends do.
	if progressionServiceRef then
		pcall(function()
			local reached = progressionServiceRef.RecordReachedLevel(userId, session.arenaLevel)
						Debug.Warn('ArenaStart', ('terminal reached recorded user=%s session=%d stage=%d lastReached=%d'):format(
					tostring(userId),
					session.sessionId,
					tonumber(session.arenaLevel) or 0,
					reached
				))
		end)
	end
	-- Frozen accumulator copy for audit logging (settle consumes it).
	local accumCash = '0'
	pcall(function()
		local accum = session.rewardAccum
		if type(accum) == 'table' and type(accum.cash) == 'string' then
			accumCash = accum.cash
		end
	end)
	local settle = settleRaidReward(userId, session, completed)
	-- Terminal restore: the team returns to its exact Arena
	-- stands BEFORE per-animal XP grants, so level-up
	-- celebration + overhead repaint land on the live stand
	-- models (victory, defeat, and broken-transition paths).
	setRaidDeployment(session, false)
	-- The player's Adv returns to its EXACT original
	-- transparency (win and loss alike).
	_restoreAdv(userId)
	session.state = if completed then 'Completed' else 'Failed'
		Debug.Warn('ArenaReward', ('Finalizing user=%s session=%d outcome=%s stage=%s'):format(
			tostring(userId),
			session.sessionId,
			if completed then 'Victory' else 'Defeat',
			tostring(outcome.Stage)
		))
	if completed then
				Debug.Warn('ArenaReward', ('Cash before=%s calculated=%s granted=%s after=%s paid=%s'):format(
				tostring(settle.oldMoney),
				accumCash,
				tostring(settle.cash),
				tostring(settle.newMoney),
				tostring(settle.paid == true)
			))
		if settle.paid ~= true then
			warn(
				('[ArenaReward] Cash grant FAILED user=%s session=%d (see REWARD_SETTLEMENT warnings for reason)'):format(
					tostring(userId),
					session.sessionId
				)
			)
		end
	else
		Debug.Warn('ArenaReward', ('DefeatSettlement settled cash=%s xp=%d paid=%s (cleared stages kept, failed stage forfeited)'):format(
				tostring(settle.cash),
				tonumber(settle.xp) or 0,
				tostring(settle.paid == true)
			))
	end
	-- Per-animal XP (progressive, same as cash): whenever the raid
	-- settled a positive XP total — victory OR defeat — the
	-- distributable pool (settled-raid-XP x AnimalXPMultiplier,
	-- applied EXACTLY ONCE here, never inside AddXP, never on
	-- the accumulator) is SPLIT across the full participant
	-- roster proportionally to actual damage dealt (see
	-- carryBattleDamage). Each share routes through canonical
	-- AnimalService:AddXP, which owns multi-level draining,
	-- MaxLevel clamp, persistence, and the per-animal
	-- XPModifier. Dead animals keep their earned share: roster
	-- membership (not aliveness) determines eligibility.
	local preLevels: { [string]: number } = {}
	local preXP: { [string]: number } = {}
	local awards: { [string]: any } = {}
	local damageByAnimal: { [string]: number } = {}
	local damageShare: { [string]: number } = {}
	local settledXPForAnimals = tonumber(settle.xp) or 0
	if settledXPForAnimals ~= settledXPForAnimals or settledXPForAnimals < 0 then
		settledXPForAnimals = 0
	end
	-- Stable terminal roster: the raid's immutable loadout
	-- snapshot (session.team), NEVER the live battle team. The
	-- roster is fixed at raid start and cannot shrink as animals
	-- die, so a 3-animal entry always settles 3 result cards.
	-- Falls back to the battle team only for legacy/test
	-- sessions without a locked team.
	local terminalRoster: { any } = {}
	if type(session.team) == 'table' and #session.team > 0 then
		for _, member in ipairs(session.team) do
			if type(member) == 'table' and type(member.UniqueId) == 'string' then
				terminalRoster[#terminalRoster + 1] = {
					SourceAnimalId = member.UniqueId,
					DefinitionId = member.DefinitionId,
					DisplayName = member.DisplayName,
					Rarity = member.Rarity,
					Level = member.Level,
					Trait = member.Trait,
					Mutations = member.Mutations,
				}
			end
		end
	end
	if #terminalRoster == 0 then
		local combatants = session.battle and session.battle.playerTeam or nil
		if type(combatants) == 'table' then
			for _, c in ipairs(combatants) do
				if type(c) == 'table' and type(c.SourceAnimalId) == 'string' then
					terminalRoster[#terminalRoster + 1] = c
				end
			end
		end
	end
	-- Aliveness overlay for the result rows (display only — XP
	-- eligibility never checks it). Raid HP snapshots on the
	-- win path already; the loss path snapshots below too.
	for _, entry in ipairs(terminalRoster) do
		if type(entry) == 'table' and type(entry.SourceAnimalId) == 'string' then
			local uid: string = entry.SourceAnimalId
			local aliveKnown: boolean? = nil
			if type(session.raidAlive) == 'table' and session.raidAlive[uid] ~= nil then
				aliveKnown = session.raidAlive[uid] == true
			else
				local battle = session.battle
				if type(battle) == 'table' and type(battle.playerTeam) == 'table' then
					for _, c in ipairs(battle.playerTeam) do
						if type(c) == 'table' and c.SourceAnimalId == uid then
							aliveKnown = c.Alive == true
							break
						end
					end
				end
			end
			entry.Alive = aliveKnown == true
		end
	end
	if settledXPForAnimals > 0 then
		local mult = 0
		pcall(function()
			mult = ArenaConfig.AnimalXPMultiplier()
		end)
		if type(mult) ~= 'number' or mult ~= mult or mult < 0 or mult == math.huge then
			mult = 0
		end
		local totalXP = tonumber(settle.xp) or 0
		if totalXP ~= totalXP or totalXP < 0 then
			totalXP = 0
		end
		-- The pool is ONE total split N ways (not N copies).
		local pool = math.floor(totalXP * mult)
		if type(session.damageDealt) ~= 'table' then
			session.damageDealt = {}
		end
		local totalDamage = 0
		for _, entry in ipairs(terminalRoster) do
			if type(entry) == 'table' and type(entry.SourceAnimalId) == 'string' then
				local d = tonumber(session.damageDealt[entry.SourceAnimalId]) or 0
				if d ~= d or d < 0 then
					d = 0
				end
				damageByAnimal[entry.SourceAnimalId] = d
				totalDamage += d
			end
		end
				Debug.Warn('ArenaXP', ('session=%s totalXP=%d pool=%d totalDamage=%d participants=%d'):format(
				tostring(session.sessionId),
				totalXP,
				pool,
				math.floor(totalDamage),
				#terminalRoster
			))
		if pool > 0 and #terminalRoster > 0 and animalServiceRef ~= nil and animalServiceRef.AddXP ~= nil then
			-- Integer shares with largest-remainder distribution so
			-- the awarded sum ALWAYS equals the pool (no dust lost
			-- to independent flooring).
			local planned: { [string]: number } = {}
			local fractions: { { uid: string, frac: number } } = {}
			local assigned = 0
			if totalDamage <= 0 then
				-- Zero-damage fallback: NOBODY dealt damage (wiped
				-- before landing a hit, or damage tracking absent
				-- on legacy sessions). Split the pool EQUALLY so
				-- the reward is never silently lost.
								Debug.Warn('ArenaXP', ('session=%s totalDamage=0 fallback=equal-split participants=%d'):format(
						tostring(session.sessionId),
						#terminalRoster
					))
				local each = math.floor(pool / #terminalRoster)
				for _, entry in ipairs(terminalRoster) do
					planned[entry.SourceAnimalId] = each
					fractions[#fractions + 1] = { uid = entry.SourceAnimalId, frac = 0 }
					assigned += each
				end
				-- Equal shares: remainder goes to roster order.
				local remainder = pool - assigned
				local i = 1
				while remainder > 0 and #fractions > 0 do
					local uid = fractions[((i - 1) % #fractions) + 1].uid
					planned[uid] = planned[uid] + 1
					remainder -= 1
					i += 1
				end
				for _, entry in ipairs(terminalRoster) do
					damageShare[entry.SourceAnimalId] = 1 / #terminalRoster
				end
			else
				for _, entry in ipairs(terminalRoster) do
					local uid: string = entry.SourceAnimalId
					local shareOf = (damageByAnimal[uid] or 0) / totalDamage
					damageShare[uid] = shareOf
					local raw = pool * shareOf
					local floored = math.floor(raw)
					planned[uid] = floored
					fractions[#fractions + 1] = { uid = uid, frac = raw - floored }
					assigned += floored
				end
				local remainder = pool - assigned
				table.sort(fractions, function(a, b)
					return a.frac > b.frac
				end)
				local i = 1
				while remainder > 0 and #fractions > 0 do
					local uid = fractions[((i - 1) % #fractions) + 1].uid
					planned[uid] = planned[uid] + 1
					remainder -= 1
					i += 1
				end
			end
			local seen: { [string]: boolean } = {}
			for _, entry in ipairs(terminalRoster) do
				if
					type(entry) == 'table'
					and type(entry.SourceAnimalId) == 'string'
					and not seen[entry.SourceAnimalId]
				then
					local uid: string = entry.SourceAnimalId
					seen[uid] = true
					local perAnimalXP = planned[uid] or 0
					local rec: any = nil
					pcall(function()
						rec = animalServiceRef.Get(uid)
					end)
					if type(rec) == 'table' then
						local lb = tonumber(rec.Level) or 1
						if lb ~= lb or lb < 1 then
							lb = 1
						end
						lb = math.floor(lb)
						local xpBefore = tonumber(rec.XP) or 0
						if xpBefore ~= xpBefore or xpBefore < 0 then
							xpBefore = 0
						end
						preLevels[uid] = lb
						preXP[uid] = math.floor(xpBefore)
						if perAnimalXP > 0 then
							-- Colon semantics via explicit self: the real
							-- AnimalService defines AddXP with colon, so
							-- self must travel explicitly here.
							local okGrant, res = pcall(animalServiceRef.AddXP, animalServiceRef, uid, perAnimalXP)
							if okGrant and type(res) == 'table' and res.success == true then
								local la = tonumber(res.level) or lb
								if la ~= la or la < 1 then
									la = lb
								end
								local xpAfter = tonumber(res.newXP)
								if xpAfter == nil or xpAfter ~= xpAfter or xpAfter < 0 then
									xpAfter = xpBefore
								end
								awards[uid] = {
									LevelAfter = math.floor(la),
									XPAwarded = perAnimalXP,
									XPAfter = math.floor(xpAfter),
								}
																Debug.Warn('ArenaXP', ('animal=%s damage=%d share=%.2f%% xp=%d after=%d levels %d->%d'):format(
										uid,
										math.floor(damageByAnimal[uid] or 0),
										(damageShare[uid] or 0) * 100,
										perAnimalXP,
										math.floor(xpAfter),
										lb,
										math.floor(la)
									))
							else
								local reason = 'unknown'
								if okGrant and type(res) == 'table' and res.error ~= nil then
									reason = tostring(res.error)
								elseif not okGrant then
									reason = tostring(res)
								end
								warn(('[ArenaReward] Animal %s XP grant FAILED: %s'):format(uid, reason))
							end
						else
							-- Zero share (no damage, pool exhausted by
							-- flooring): still snapshot so the row
							-- renders honestly with +0 XP.
							awards[uid] = { LevelAfter = lb, XPAwarded = 0, XPAfter = math.floor(xpBefore) }
														Debug.Warn('ArenaXP', ('animal=%s damage=%d share=%.2f%% xp=0 (zero share)'):format(
									uid,
									math.floor(damageByAnimal[uid] or 0),
									(damageShare[uid] or 0) * 100
								))
						end
					end
				end
			end
			-- Conservation check: awarded sum must equal the pool
			-- (largest-remainder distribution guarantees it; this
			-- log makes it verifiable in Studio).
			local distributed = 0
			for _, award in pairs(awards) do
				if type(award) == 'table' then
					local xa = tonumber(award.XPAwarded) or 0
					if xa == xa and xa > 0 then
						distributed += xa
					end
				end
			end
						Debug.Warn('ArenaXP', ('session=%s distributedXP=%d pool=%d'):format(
					tostring(session.sessionId),
					math.floor(distributed),
					pool
				))
		end
	end
	-- Snapshot the result-screen rows BEFORE battle-model teardown.
	-- Records persist regardless, but the snapshot pins the exact
	-- end-of-raid presentation (never live-read later). PreLevels
	-- pin pre-grant levels; Awards carry committed grants only;
	-- Damage/DamageShare carry the authoritative contribution.
	-- The roster is the stable session team (see above): card
	-- count == participant count, even when all died.
	local resultAnimals: { { [string]: any } } = {}
	pcall(function()
		local function getAnimal(uid: string): any
			if animalServiceRef == nil or animalServiceRef.Get == nil then
				return nil
			end
			return animalServiceRef.Get(uid)
		end
		resultAnimals = buildResultAnimals(terminalRoster, getAnimal, {
			PreLevels = preLevels,
			PreXP = preXP,
			Awards = awards,
			Damage = damageByAnimal,
			DamageShare = damageShare,
			CombatModels = if type(session.keepsakeModels) == 'table' then session.keepsakeModels else nil,
		})
	end)
		Debug.Warn('ArenaResult', ('session=%s participants=%d cards=%d'):format(
			tostring(session.sessionId),
			#terminalRoster,
			#resultAnimals
		))
	ArenaService.cleanupBattleModels(session, TERMINAL_CLEANUP_DELAY)
	sessions[userId] = nil
	if battleServiceRef then
		pcall(battleServiceRef.UnregisterBattle, userId)
	end
	outcome.SessionId = session.sessionId
	outcome.MaxStage = session.maxLevel or ArenaConfig.MaxLevel()
	-- Results show the SETTLED totals on every terminal path:
	-- the same cash/XP that settleRaidReward just committed
	-- (progressive accumulator on defeat, full accumulator on
	-- victory, $0/0 when nothing was cleared). The result screen
	-- renders these verbatim — it never recomputes rewards.
	outcome.EarnedCash = settle.cash or '0'
	outcome.EarnedXP = tonumber(settle.xp) or 0
	outcome.Paid = settle.paid == true
	local highestCleared = 0
	if type(session.clearedStages) == 'table' then
		highestCleared = #session.clearedStages
	end
	outcome.HighestClearedWave = highestCleared
		Debug.Warn('ArenaReward', ('SettlementCommitted runId=%s cash=%s xp=%d highestClearedWave=%d'):format(
			tostring(session.sessionId),
			tostring(outcome.EarnedCash),
			outcome.EarnedXP,
			highestCleared
		))
	-- Server-decided outcome + finalized snapshot for the result
	-- screen. No egg economy exists in raids, so Eggs is honestly
	-- empty (client shows the NoEggs state).
	outcome.Outcome = if completed then 'Victory' else 'Defeat'
	outcome.Animals = resultAnimals
	outcome.Eggs = {}
	-- Pre-send payload proof: EVERY card logged with identity
	-- (count alone could hide a wrong-animal bug). The roster
	-- here must equal the [ArenaParticipants] roster at start,
	-- regardless of death order.
		Debug.Warn('ArenaResultPayload', ('session=%s participants=%d'):format(tostring(session.sessionId), #resultAnimals))
		Debug.Warn('ArenaResultPayload', ('session=%s sessionTeamCount=%d terminalRosterCount=%d outcomeAnimalsCount=%d'):format(
			tostring(session.sessionId),
			if type(session.team) == 'table' then #session.team else 0,
			#terminalRoster,
			#resultAnimals
		))
	for i, entry in ipairs(terminalRoster) do
		if type(entry) == 'table' then
						Debug.Warn('ArenaResultPayload', ('roster=%d uid=%s name=%s defId=%s'):format(
					i,
					tostring(entry.SourceAnimalId),
					tostring(entry.DisplayName),
					tostring(entry.DefinitionId)
				))
		end
	end
		for i, row in ipairs(resultAnimals) do
		if type(row) == 'table' then
			local combatPath = 'ERROR=missing-keepsake'
			local combatClass = 'nil'
			if typeof(row.CombatModel) == 'Instance' then
				pcall(function()
					combatPath = (row.CombatModel :: Instance):GetFullName()
					combatClass = (row.CombatModel :: Instance).ClassName
				end)
			end
			if combatPath == 'ERROR=missing-keepsake' then
				warn(
					('[ArenaResultModel] ERROR missing live combat model session=%s combatant=%s expectedModel=ReplicatedStorage.ArenaResultModels/Session_%s'):format(
						tostring(session.sessionId),
						tostring(row.UniqueId),
						tostring(session.sessionId)
					)
				)
			else
								Debug.Warn('ArenaResultModel', ('session=%s participant=%s combatModel=%s class=%s'):format(
						tostring(session.sessionId),
						tostring(row.UniqueId),
						combatPath,
						combatClass
					))
			end
						Debug.Warn('ArenaResultPayload', ('session=%s card=%d uniqueId=%s def=%s name=%s damage=%d xp=%d'):format(
					tostring(session.sessionId),
					i,
					tostring(row.UniqueId),
					tostring(row.DefinitionId),
					tostring(row.DisplayName),
					tonumber(row.Damage) or 0,
					tonumber(row.XP) or 0
				))
						Debug.Warn('ArenaResultPayload', ('outcome=%d uid=%s name=%s'):format(
					i,
					tostring(row.UniqueId),
					tostring(row.DisplayName)
				))
		end
	end
	local cleared = 0
	if type(session.clearedStages) == 'table' then
		cleared = #session.clearedStages
	end
	outcome.StagesCleared = cleared
	lastRaid[userId] = outcome
	Debug.Warn('ArenaRaid', ('%s user=%s session=%d stage=%d/%d%s'):format(
			if outcome.RaidComplete == true then 'RAID_COMPLETE' else 'RAID_FAILED',
			tostring(userId),
			session.sessionId,
			session.arenaLevel,
			(session.maxLevel or ArenaConfig.MaxLevel()),
			if outcome.Reason ~= nil then ' reason=' .. tostring(outcome.Reason) else ''
		))
	Debug.Log('Arena', 'raid terminated', {
		userId = tostring(userId),
		session = tostring(session.sessionId),
		complete = tostring(outcome.RaidComplete == true),
	})
	local player: Player? = nil
	pcall(function()
		player = Players:GetPlayerByUserId(userId)
	end)
	if player then
				Debug.Warn('ArenaResult', ('SEND session=%s outcome=%s stage=%s rewardCash=%s rewardXP=%d'):format(
				tostring(outcome.SessionId),
				tostring(outcome.Outcome),
				tostring(outcome.Stage),
				tostring(outcome.EarnedCash),
				tonumber(outcome.EarnedXP) or 0
			))
		pushResult(player, 'RaidEnd', true, nil, {
			RaidComplete = outcome.RaidComplete == true,
			Outcome = outcome.Outcome,
			Stage = outcome.Stage,
			MaxStage = outcome.MaxStage,
			EarnedCash = outcome.EarnedCash,
			EarnedXP = outcome.EarnedXP,
			HighestClearedWave = outcome.HighestClearedWave,
			Animals = outcome.Animals,
			Eggs = outcome.Eggs,
			SessionId = outcome.SessionId,
		})
		ArenaService.PushState(player)
		-- Tutorial guide layer observes the terminal raid end
		-- (bus never throws; rewards already committed above).
		pcall(TutorialSignals.Fire, 'ArenaEnded', { UserId = userId })
		-- Funnel: full completion ONLY (RaidComplete). Defeats
		-- and retreats settle progressively but are not
		-- completions; is_first_clear is omitted (not cleanly
		-- available at this point).
		if outcome.RaidComplete == true then
			pcall(function()
				local meta = { stage = outcome.Stage }
				FunnelService:LogStep(player, 'Arena', 'ArenaCompleted', meta)
				FunnelService:LogStep(player, 'Onboarding', 'FirstArenaCompleted', nil)
				-- Player monitoring: full completion only.
				pcall(PlayerLogger.LogMilestone, player, 'ArenaCompleted', { stage = outcome.Stage })
			end)
		end
	end
	Debug.Warn('ArenaReward', 'Eggs granted=none (no arena egg economy; honest empty payload)')
		Debug.Warn('ArenaReward', ('Completion finalized user=%s session=%d animals=%d'):format(
			tostring(userId),
			session.sessionId,
			#resultAnimals
		))
	-- Keepsake retirement: the client clones its viewport copies
	-- within seconds of receipt (deferred fill + bounded GUI
	-- retry). Destroy this session's keepsake folder after a
	-- generous window; the per-clone Debris backup covers
	-- abandoned raids. Battle-folder cleanup is independent.
	local finishedSessionId = session.sessionId
	task.delay(60, function()
		pcall(function()
			if battleServiceRef then
				battleServiceRef.ClearSessionKeepsakes(finishedSessionId)
			end
		end)
	end)
end

-- Stage-end settlement (battle service callback). Exactly
-- once per (session, stage, generation): the session must be
-- Active, the sessionId AND stageGeneration must match, and
-- the stage must not have settled yet — otherwise the
-- callback is ignored with NO accumulator change and NO
-- state change. Win path: snapshot raid HP -> accumulate
-- the stage contribution -> final stage ? RAID COMPLETE
-- (settle once) : advance to the next stage inline (same
-- session). Loss path: snapshot HP + damage, end the raid;
-- the accumulator settles progressively (cleared stages pay,
-- no warning toast). Persistent animals are
-- untouched on every path.
function ArenaService.CompleteBattle(
	userId: number,
	sessionId: number,
	won: boolean,
	stageGen: number?
): { [string]: any }
	if type(userId) ~= 'number' or type(sessionId) ~= 'number' then
		return { success = false, error = 'invalid-args' }
	end
	local session = sessions[userId]
	if session == nil or session.sessionId ~= sessionId then
				Debug.Warn('ArenaRaid', ('Settlement SKIPPED user=%s session=%s reason=stale_session'):format(
				tostring(userId),
				tostring(sessionId)
			))
		Debug.Log('Arena', 'stale battle end ignored', {
			userId = tostring(userId),
			session = tostring(sessionId),
		})
		return { success = false, error = 'stale-session' }
	end
	-- Stage-generation gate: nil matches only nil (gen-less
	-- legacy/test sessions). Raid sessions always carry a
	-- generation, so a delayed callback from a previous
	-- stage can never settle the current one.
	if session.stageGeneration ~= stageGen then
				Debug.Warn('ArenaRaid', ('Settlement SKIPPED user=%s session=%d reason=stale_stage gen=%s expected=%s'):format(
				tostring(userId),
				sessionId,
				tostring(stageGen),
				tostring(session.stageGeneration)
			))
		return { success = false, error = 'stale-stage' }
	end
	if session.state ~= 'Active' then
				Debug.Warn('ArenaRaid', ('Settlement SKIPPED user=%s session=%d reason=already_settled state=%s'):format(
				tostring(userId),
				sessionId,
				tostring(session.state)
			))
		return { success = false, error = 'already-settled' }
	end
	local stage = session.arenaLevel
	if type(session.settledStages) ~= 'table' then
		session.settledStages = {}
	end
	if session.settledStages[stage] == true then
				Debug.Warn('ArenaRaid', ('Settlement SKIPPED user=%s session=%d stage=%d reason=duplicate'):format(
				tostring(userId),
				sessionId,
				stage
			))
		return { success = false, error = 'already-settled' }
	end
	session.state = 'Completing'
	session.settledStages[stage] = true
	-- Freeze this stage's ending HP into the run BEFORE any
	-- reward/advance decision. Next stages build from here.
	snapshotRaidHP(session)
	-- Freeze this stage's damage ledger into the run as well
	-- (drives the terminal proportional XP split).
	carryBattleDamage(session)
	-- Capture survivors' combat models + drain death-time
	-- captures into the session (drives result viewports).
	-- Must run BEFORE any advance/terminate cleanup below.
	carryKeepsakes(session)
	if won then
				Debug.Warn('ArenaRaid', ('STAGE_WIN user=%s session=%d stage=%d/%d gen=%d'):format(
				tostring(userId),
				sessionId,
				stage,
				(session.maxLevel or ArenaConfig.MaxLevel()),
				(session.stageGeneration or 0)
			))
		-- Stage win contributes to the accumulator (no
		-- payout, no XP, no toast mid-raid).
		accumulateStageReward(session, stage)
		-- Funnel: milestone stages only (1/5/10/25/50) — every
		-- stage win would be noise.
		if FunnelService.IsArenaMilestone(stage) then
			pcall(function()
				local stagePlayer: Player? = nil
				pcall(function()
					stagePlayer = Players:GetPlayerByUserId(userId)
				end)
				if stagePlayer then
					FunnelService:LogStep(stagePlayer, 'Arena', 'StageProgressed', {
						stage = stage,
						_key = tostring(stage),
					})
				end
			end)
		end
		if stage >= (session.maxLevel or ArenaConfig.MaxLevel()) then
			terminateRaid(userId, session, { RaidComplete = true, Stage = stage })
			return { success = true, won = true, raidComplete = true }
		end
		-- Advance guard: the won stage may still have wiped
		-- the team (engine resolves the attacker's kill first,
		-- so a mutual wipe reports won). With nobody standing
		-- there is no next stage: the raid ends FAILED, but the
		-- accumulated contribution (including this cleared
		-- stage) is still settled progressively.
		local standing = 0
		if type(session.raidAlive) == 'table' then
			for _, alive in pairs(session.raidAlive) do
				if alive == true then
					standing += 1
				end
			end
		end
		if standing < 1 then
						Debug.Warn('ArenaRaid', ('STAGE_WIN with no survivors user=%s session=%d stage=%d (raid ends, no advance)'):format(
					tostring(userId),
					sessionId,
					stage
				))
			terminateRaid(userId, session, { RaidComplete = false, Stage = stage, Reason = 'all-dead' })
			return { success = true, won = true, advanced = false }
		end
		-- CONTINUOUS ADVANCE: same session, next stage, fresh
		-- generation. Old stage models are destroyed first;
		-- carried HP (never heals, dead stay dead) seeds the
		-- next battle.
		ArenaService.cleanupBattleModels(session)
		session.stageGeneration = (session.stageGeneration or 0) + 1
		session.arenaLevel = stage + 1
		session.state = 'Transitioning'
		local base: any = nil
		if baseServiceRef then
			pcall(function()
				base = baseServiceRef.GetBaseByOwner(userId)
			end)
		end
		if base == nil and baseServiceRef then
			-- Base gone mid-raid (release/leave): end the raid
			-- safely, earned rewards kept, no further stages.
			terminateRaid(userId, session, { RaidComplete = false, Stage = stage, Reason = 'no-base' })
			return { success = true, won = true, advanced = false }
		end
		if not startStageBattle(session, base) then
			terminateRaid(userId, session, { RaidComplete = false, Stage = stage, Reason = 'transition-failed' })
			return { success = true, won = true, advanced = false }
		end
				Debug.Warn('ArenaRaid', ('STAGE_ADVANCE user=%s session=%d from=%d to=%d gen=%d'):format(
				tostring(userId),
				sessionId,
				stage,
				stage + 1,
				(session.stageGeneration or 0)
			))
		local player: Player? = nil
		pcall(function()
			player = Players:GetPlayerByUserId(userId)
		end)
		if player then
			ArenaService.PushState(player)
		end
		return { success = true, won = true, advanced = true }
	end
	-- Stage loss = raid ends immediately. The accumulated
	-- contributions of previously cleared stages are settled
	-- progressively (settle with completed=false); only the
	-- lost stage pays nothing. Persistent animals untouched.
	-- A wipe is a normal Arena completion for progression
	-- purposes: NO RaidFailed warning is fired here (the
	-- terminal settlement plays the single Success SFX when it
	-- pays; empty wipes stay silent). The RaidFailed catalog
	-- entry is retained for genuine setup/exploit aborts only.
	-- Final-stage HP + damage still freeze first so the result
	-- roster (built from the stable session team) carries
	-- accurate Alive flags and full contribution data.
	snapshotRaidHP(session)
	carryBattleDamage(session)
	carryKeepsakes(session)
	Debug.Warn('ArenaRaid', ('RAID_FAILED user=%s session=%d at stage=%d/%d (team wiped)'):format(
			tostring(userId),
			sessionId,
			stage,
			(session.maxLevel or ArenaConfig.MaxLevel())
		))
	terminateRaid(userId, session, { RaidComplete = false, Stage = stage })
	return { success = true, won = false }
end

-- --- State snapshot --------------------------------------------------------

-- Restart entry snapshot for the authored start menu
-- (Main.Arena Buy1/Buy2/Buy3). Display data only: the start
-- path re-resolves everything authoritatively per purchase, so
-- a stale/tampered client copy can never grant anything.
--   Buy3: free, stage 1, always available.
--   Buy2: direct restart at LastLevel (needs >= stage 2).
--   Buy1: warmup restart at floor(LastLevel / 2) (needs
--     warmup > stage 1, i.e. LastLevel >= 4).
-- Missing progression displays as LastLevel 1 (never 0);
-- paid options stay gated on real progress behind it.
local function buildRestartInfo(userId: number): { [string]: any }
	local last = 0
	if progressionServiceRef then
		pcall(function()
			last = progressionServiceRef.GetLastReached(userId)
		end)
	end
	if type(last) ~= 'number' or last ~= math.floor(last) or last < 0 then
		last = 0
	end
	if last > ArenaConfig.MaxLevel() then
		last = ArenaConfig.MaxLevel()
	end
	local warmup = ArenaConfig.RestartWarmupLevel(last) or 1
	local displayLast = math.max(1, last)
	return {
		LastLevel = displayLast,
		WarmupLevel = warmup,
		Buy1 = {
			Price = ArenaConfig.RestartWarmupPrice(),
			StartLevel = warmup,
			Available = ArenaConfig.IsRestartAvailable(last, true),
		},
		Buy2 = {
			Price = ArenaConfig.RestartDirectPrice(),
			StartLevel = ArenaConfig.RestartDirectLevel(last),
			Available = ArenaConfig.IsRestartAvailable(last, false),
		},
		Buy3 = {
			Price = '0',
			StartLevel = 1,
			Available = true,
		},
	}
end

function ArenaService.BuildState(player: Player): { [string]: any }?
	if typeof(player) ~= 'Instance' or not player:IsA('Player') then
		return nil
	end
	local userId = player.UserId
	local progression: { [string]: any } = { Level = 1, XP = 0, XPRequired = 100, Wins = 0 }
	if progressionServiceRef then
		pcall(function()
			progression = progressionServiceRef.GetArenaState(userId)
		end)
	end
	local levels: { any } = {}
	-- Historical stage record (HighestCompleted = highest
	-- stage ever reached; drives first/repeat previews and
	-- the menu's "best" line). NOT a gate: every raid starts
	-- at stage 1 and advances continuously.
	local completed = 0
	if progressionServiceRef then
		pcall(function()
			local state = progressionServiceRef.GetArenaState(userId)
			if type(state.HighestCompleted) == 'number' then
				completed = state.HighestCompleted
			end
		end)
	end
	for _, entry in ipairs(ArenaConfig.GetAll()) do
		-- Preview shows the first-clear bounty until the
		-- level is beaten, then the repeat value. Both come
		-- from config; the server picks which on win.
		local beaten = completed >= entry.Level
		local previewCash = if not beaten then entry.Rewards.FirstClearCash else entry.Rewards.RepeatCash
		local unlocked = entry.Level <= completed + 1
		-- Explicit display state derived from the same two
		-- values (no second source of truth): 'completed'
		-- (done, replayable), 'available' (next up), 'locked'.
		local displayState = if beaten then 'completed' elseif unlocked then 'available' else 'locked'
		levels[#levels + 1] = {
			Level = entry.Level,
			Name = entry.Name,
			Description = entry.Description,
			Boss = entry.Boss,
			Unlocked = unlocked,
			State = displayState,
			RewardXP = entry.Rewards.ArenaXP,
			RewardCash = previewCash,
			RewardCashText = formatCash(previewCash),
			Beaten = beaten,
		}
	end
	local session = sessions[userId]
	local sessionView: any = nil
	if session ~= nil then
		-- Stage display name comes from the catalog (single
		-- authority: ArenaConfig), never from the client.
		local stageName: string? = nil
		pcall(function()
			local def = ArenaConfig.FindLevel(session.arenaLevel)
			if def ~= nil then
				stageName = def.Name
			end
		end)
		sessionView = {
			SessionId = session.sessionId,
			ArenaLevel = session.arenaLevel,
			Stage = session.arenaLevel,
			MaxStage = session.maxLevel,
			StageName = stageName,
			StageGeneration = session.stageGeneration,
			State = session.state,
			TeamCount = #(session.team or {}),
			AreaReady = session.areaReady == true,
		}
		if session.battle ~= nil and type(session.battle) == 'table' then
			local battleView: { [string]: any } = { State = session.battle.state }
			local function summarize(team: any): { any }
				local out: { any } = {}
				if type(team) == 'table' then
					for _, c in ipairs(team) do
						if type(c) == 'table' then
							out[#out + 1] = {
								UniqueId = c.SourceAnimalId,
								DefinitionId = c.DefinitionId,
								DisplayName = c.DisplayName,
								Level = c.Level,
								Health = c.CurrentHealth,
								MaxHealth = c.MaxHealth,
								Alive = c.Alive == true,
								IsBoss = c.IsBoss == true,
							}
						end
					end
				end
				return out
			end
			battleView.PlayerTeam = summarize(session.battle.playerTeam)
			battleView.EnemyTeam = summarize(session.battle.enemyTeam)
			sessionView.Battle = battleView
			-- Authoritative run roster for the raid UI: the
			-- same combatants, trimmed to run state.
			local raidTeam: { any } = {}
			if type(session.battle.playerTeam) == 'table' then
				for _, c in ipairs(session.battle.playerTeam) do
					if type(c) == 'table' then
						raidTeam[#raidTeam + 1] = {
							UniqueId = c.SourceAnimalId,
							DefinitionId = c.DefinitionId,
							DisplayName = c.DisplayName,
							Level = c.Level,
							Health = c.CurrentHealth,
							MaxHealth = c.MaxHealth,
							Alive = c.Alive == true,
						}
					end
				end
			end
			sessionView.Raid = {
				Stage = session.arenaLevel,
				MaxStage = session.maxLevel,
				StageName = stageName,
				Generation = session.stageGeneration,
				Team = raidTeam,
			}
		end
	end
	-- Pre-raid loadout preview: the CURRENT occupied arena
	-- slots (what START would lock). Display-only; Start
	-- re-resolves and validates authoritatively.
	local loadout: { [string]: any }? = nil
	if session == nil then
		local resolved = ArenaService.ResolveArenaTeam(userId)
		local members: { any } = {}
		if type(resolved.members) == 'table' then
			for _, m in ipairs(resolved.members) do
				if type(m) == 'table' then
					local maxHp: number? = nil
					pcall(function()
						local h = AnimalStats.Calculate({ DefId = m.DefinitionId, Level = m.Level or 1 }, 'Health')
						if type(h) == 'number' and h == h and h > 0 then
							maxHp = h
						end
					end)
					members[#members + 1] = {
						UniqueId = m.UniqueId,
						DefinitionId = m.DefinitionId,
						DisplayName = m.DisplayName,
						Rarity = m.Rarity,
						Level = m.Level,
						MaxHealth = maxHp,
					}
				end
			end
		end
		loadout = {
			Members = members,
			Count = #members,
			MinTeam = ArenaConfig.MinTeamSize(),
			MaxTeam = ArenaConfig.MaxTeamSize(),
		}
	end
	return {
		Progression = progression,
		Levels = levels,
		Session = sessionView,
		Loadout = loadout,
		LastRaid = lastRaid[userId],
		Restart = buildRestartInfo(userId),
		Dialogue = {
			Greeting = ArenaConfig.Dialogue('Greeting'),
			Normal = ArenaConfig.Dialogue('Normal'),
			High = ArenaConfig.Dialogue('High'),
			Boss = ArenaConfig.Dialogue('Boss'),
		},
	}
end

function ArenaService.PushState(player: Player, show: boolean?)
	local state = ArenaService.BuildState(player)
	if not state then
		return
	end
	state.Show = show == true
	pcall(Remotes.FireClient, player, Remotes.Names.ArenaState, state)
end

-- --- Remote ingress --------------------------------------------------------

local function handleAction(player: Player, payload: any)
	local ok, err = pcall(function()
		if not Validation.LivePlayer(player) then
			return
		end
		if type(payload) ~= 'table' or type(payload.Action) ~= 'string' then
			warn(('[Arena] Malformed action from player=%s'):format(player.Name))
			return
		end
		if payload.Action == 'Open' then
			ArenaService.OpenArena(player)
		elseif payload.Action == 'Start' or payload.Action == 'StartRaid' then
			-- ONE authoritative raid path: the client names ONLY
			-- the option ('Buy1' | 'Buy2' | 'Buy3'); the server
			-- resolves the starting stage + price per request and
			-- charges before the session exists. Any client-sent
			-- level or price is ignored.
			local result = ArenaService.StartArena(player, payload.Option)
			pushResult(player, 'Start', result.success == true, result.error, {
				SessionId = result.sessionId,
				StartLevel = result.startLevel,
			})
			ArenaService.PushState(player, result.success == true and false or nil)
		elseif payload.Action == 'Cancel' then
			local result = ArenaService.CancelArena(player)
			pushResult(player, 'Cancel', result.success == true, result.error)
			ArenaService.PushState(player)
		else
			warn(('[Arena] Unknown action=%s from player=%s'):format(tostring(payload.Action), player.Name))
		end
	end)
	if not ok then
		warn(('[Arena] Action handler errored: %s'):format(tostring(err)))
	end
end

-- --- Init ---------------------------------------------------------------------

function ArenaService.Init()
	if started then
		return
	end
	started = true
	for _, issue in ipairs(ArenaConfig.ValidateLive()) do
		warn(('[Arena] Config issue: %s'):format(issue))
	end
	if battleServiceRef then
		-- Per-tick battle validity: player present, base
		-- still theirs, models folder live, session still
		-- this raid AND this stage generation. Anything else
		-- cancels with no reward.
		--
		-- CHARACTER DEATH IS INTENTIONALLY NOT CHECKED HERE.
		-- Combatants are server-owned clones; the avatar is
		-- not required once the raid starts, so a reset
		-- mid-raid can neither duplicate a stage, award a
		-- win, nor corrupt persistent animals — the fight
		-- simply runs to its real terminal state.
		pcall(battleServiceRef.SetValidator, function(battle: any): boolean
			if type(battle) ~= 'table' then
				return false
			end
			local userId = battle.userId
			if type(userId) ~= 'number' then
				return false
			end
			local present = false
			pcall(function()
				present = Players:GetPlayerByUserId(userId) ~= nil
			end)
			if not present then
				return false
			end
			if baseServiceRef then
				local base: any = nil
				pcall(function()
					base = baseServiceRef.GetBaseByOwner(userId)
				end)
				if type(base) ~= 'table' then
					return false
				end
			end
			if battle.folder ~= nil then
				local folderLive = false
				pcall(function()
					folderLive = typeof(battle.folder) == 'Instance' and (battle.folder :: Instance).Parent ~= nil
				end)
				if not folderLive then
					return false
				end
			end
			local session = sessions[userId]
			-- Strict token match: a battle from a previous
			-- stage (same sessionId, older generation) never
			-- validates once the raid advanced.
			return session ~= nil
				and session.state == 'Active'
				and session.sessionId == battle.sessionId
				and session.stageGeneration == battle.stageGeneration
		end)
		pcall(
			battleServiceRef.SetOnBattleEnd,
			function(userId: number, sessionId: number, won: boolean, stageGen: number?)
				ArenaService.CompleteBattle(userId, sessionId, won, stageGen)
			end
		)
		pcall(battleServiceRef.SetOnBattleCancel, function(userId: number, sessionId: number, stageGen: number?)
			ArenaService.CancelBattleSilent(userId, sessionId, stageGen)
		end)
		-- Presentation/log feed: gated Debug line + the S->C
		-- ArenaCombatEvent. ArenaHit packets (the single
		-- authoritative impact per attack) broadcast to EVERY
		-- client — spectators present the same world-anchored
		-- bundle locally (distance-culled camera only for
		-- non-owners); all other events stay owner-targeted.
		-- Never trusted inbound; never drives the sim.
		pcall(battleServiceRef.SetEventSink, function(userId: number, event: { [string]: any })
			if type(event) ~= 'table' then
				return
			end
			Debug.Log('ArenaCombat', tostring(event.Event), {
				user = tostring(userId),
				session = tostring(event.SessionId),
			})
			if event.Event == 'ArenaHit' then
				pcall(Remotes.FireAllClients, Remotes.Names.ArenaCombatEvent, event)
				return
			end
			local player: Player? = nil
			pcall(function()
				player = Players:GetPlayerByUserId(userId)
			end)
			if player then
				pcall(Remotes.FireClient, player, Remotes.Names.ArenaCombatEvent, event)
			end
		end)
	end
	local ok, err = pcall(function()
		local folder = Remotes.GetFolder()
		local remote = folder:WaitForChild(Remotes.Names.ArenaAction, 10)
		-- NOTE: keep the assert and the Connect as separate
		-- statements. Fusing them as
		-- `assert(...)(remote).OnServerEvent:Connect(...)`
		-- calls assert's boolean return as a function and
		-- breaks ALL Arena actions (same bug class as the old
		-- prompt wiring).
		assert(remote and (remote :: Instance):IsA('RemoteEvent'), 'ArenaAction remote missing')
		local actionRemote = remote :: RemoteEvent
		actionRemote.OnServerEvent:Connect(handleAction)
		Debug.Log('Arena', 'Action remote wiring complete', {})
	end)
	if not ok then
		warn(('[Arena] Action remote wiring failed: %s'):format(tostring(err)))
	end
	-- Late-join self-heal for Studio: wire prompts for bases
	-- already assigned before Init ran.
	pcall(function()
		if baseServiceRef then
			for _, base in pairs(baseServiceRef.GetAllBases()) do
				if type(base) == 'table' and (base :: any).state == 'Occupied' then
					pcall(ArenaService.EnsureAdventurer, base)
				end
			end
		end
	end)
	Debug.Log('AS', 'Init done')
end

function ArenaService._TestReset()
	table.clear(sessions)
	table.clear(lastRaid)
	table.clear(_advHidden)
	nextSessionId = 1
end

-- TEST-ONLY seam: resolve a Buy1/Buy2/Buy3 purchase (start
-- level + price from SAVED LastLevel) without a live player,
-- so the final purchase table is headless-testable.
function ArenaService._TestResolveRestart(userId: number, option: any): { [string]: any }
	return resolveRestartStart(userId, option)
end

-- TEST-ONLY seam: seed a session without a live player so
-- settle/cancel paths are headless-testable.
function ArenaService._TestInjectSession(userId: number, session: { [string]: any })
	if type(userId) == 'number' and type(session) == 'table' then
		sessions[userId] = session
	end
end

-- TEST-ONLY seam: drive stand parking + collector escrow for a
-- session without a live raid (deploy = snapshot/zero/park).
function ArenaService._TestSetRaidDeployment(session: { [string]: any }, deployed: boolean)
	if type(session) == 'table' then
		setRaidDeployment(session, deployed)
	end
end

-- TEST-ONLY seam: run the full terminal pipeline headlessly
-- (settle -> per-animal grants -> snapshot -> teardown) and
-- return the mutated outcome, so reward state changes are
-- assertable without a live player (FireClient/PlayerService
-- paths are player-nil-safe and skip).
function ArenaService._TestTerminateRaid(
	userId: number,
	session: { [string]: any },
	outcome: { [string]: any }
): { [string]: any }?
	if type(userId) ~= 'number' or type(session) ~= 'table' or type(outcome) ~= 'table' then
		return nil
	end
	terminateRaid(userId, session, outcome)
	return outcome
end

-- TEST-ONLY seam: pure end-of-raid row builder (no Workspace,
-- no grants) so the result snapshot is headless-testable.
-- `extras` (optional): { PreLevels = {uid=level}, PreXP =
-- {uid=xp}, Awards = {uid={LevelAfter, XPAwarded, XPAfter}},
-- Damage = {uid=amount}, DamageShare = {uid=0..1},
-- CombatModels = {uid=Model} }
-- from committed grants + the authoritative contribution map +
-- captured combat keepsakes.
function ArenaService._TestBuildResultAnimals(
	combatants: any,
	getAnimal: any,
	extras: { [string]: any }?
): { { [string]: any } }
	return buildResultAnimals(combatants, getAnimal, extras)
end

return table.freeze(ArenaService)
