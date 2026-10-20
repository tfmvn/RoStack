--!strict
--!native
--[[
	Steal.StealService
	==================
	Server-authoritative multiplayer stealing.

	Core loop: Player B approaches an Egg/Animal on Player A's
	unlocked base, sees a Steal prompt (non-owners only), presses
	E, carries it with the EXISTING carry system, delivers it to
	B's OWN collector, and ownership transfers A -> B with the
	object's identity and progression intact.

	Reuse (no second carry system, no steal animations):
	  * CarryRegistry — the ONE carry state. A steal is a carry
	    item with a `steal` metadata table; normal and steal
	    carries can never coexist (Set rejects while carrying).
	  * CarryController — the weld/follow behavior, unchanged.
	  * SlotService — DemoteSlotToReserved is the ATOMIC
	    reservation primitive: only one of {B-steal, C-steal,
	    A-grab} can demote the Occupied slot; losers are
	    rejected with 'slot-race'. No yields occur between
	    validation and demotion, and Start() itself is
	    yield-free, so the steal-start transaction is atomic.
	  * HoverMath.Settle / AnimalService.SettleModelAtSlot —
	    placement math for rollback/completion.
	  * PlayerService Add/Remove/Set — profile transfer that
	    preserves Id + all progression (snapshot BEFORE remove).
	  * IncomeService-style per-collector Touched — delivery
	    detection with zero polling.

	State model:
	  * Pre-transfer, the record keeps ownerUserId = A and the
	    profile keeps A's record. NOTHING is duplicated into B.
	    The CarryRegistry item carries
	    `steal = { originalOwnerUserId, originalBaseId }` and
	    the record mirrors `stolenBy = thiefUserId` (cache flag
	    for sweep guards; CarryRegistry is authoritative).
	  * Egg state during steal: 'Opening' (same as owner grab —
	    Hatch/Sell reject it). Animal state: 'Carried' (Sell
	    rejects it). Place is explicitly rejected for steal
	    items in both Place paths ('steal-in-progress'): the
	    only exit is collector delivery or rollback.
	  * Original slot stays Reserved for the whole carry, so
	    rollback tier-1 (re-occupy) almost always succeeds and
	    a rejoining owner auto-skips the record (Reserved slot
	    hits RestorePlayerBase's occupied branch — no second
	    model, no code needed).

	Failure policy: transfer order is Reserve(B) -> Add(B) ->
	Remove(A) -> place. Any failure before Remove(A) leaves A
	owning everything (carry continues, loud warn). Any failure
	after Remove(A) triggers _undoTransfer (re-Add A, drop B)
	before surfacing the error — never remove-then-fail silent.

	Performance: everything here is event-driven (prompt
	Triggered, collector Touched, death/leave hooks). No
	Heartbeat, no polling, no per-player/per-target loops, no
	GetDescendants in any path.
]]

local Players = game:GetService('Players')
local ServerScriptService = game:GetService('ServerScriptService')
local ReplicatedStorage = game:GetService('ReplicatedStorage')
local ServerStorage = game:GetService('ServerStorage')
local Debris = game:GetService('Debris')

local SlotType = require(ReplicatedStorage.Types.SlotType)
local Validation = require(ReplicatedStorage.Utility.Validation)
local RichTextFormatter = require(ReplicatedStorage.Utility.RichTextFormatter)
local StealConfig = require(ReplicatedStorage.Config.World.Stealing)
local PromptConfig = require(ReplicatedStorage.Config.World.Prompts)
local AudioConfig = require(ReplicatedStorage.Config.Presentation.Audio)
local DebugConfig = require(ReplicatedStorage.Config.Systems.Debug)
local Debug = require(ReplicatedStorage.Utility.Debug)
local AudioGroups = require(ReplicatedStorage.Utility.AudioGroups)

local SlotService = require(ServerScriptService.Base.SlotService)
local BaseService = require(ServerScriptService.BaseService)
local CarryRegistry = require(ServerScriptService.Carry.CarryRegistry)
local CarryController = require(ServerScriptService.Animal.CarryController)
local CarryPrompts = require(ServerScriptService.Animal.CarryPrompts)
-- Temporary STOLEN overhead while steal-carrying (presentation
-- only — ownership/state stay authoritative here). Leaf module,
-- cycle-free (same require AnimalService already makes).
local AnimalOverhead = require(ServerScriptService.Animal.AnimalOverhead)
local StandPresentation = require(ServerScriptService.StandPresentation)
-- Canonical player-facing rejections. Leaf module — cycle-free.
local NotificationService = require(ServerScriptService.Base.NotificationService)
-- Funnel analytics (leaf module — never gameplay-critical).
local FunnelService = require(ServerScriptService.FunnelService)
local HoverMath = require(ServerScriptService.Egg.HoverMath)
local SpawnService = require(ServerScriptService.Egg.SpawnService)
local AnimalService = require(ServerScriptService.AnimalService)
-- Raid lock: animals fighting in an active Arena raid cannot
-- be stolen mid-run (the raid fights on its immutable
-- snapshot). Require-safe: ArenaService depends only on
-- ReplicatedStorage modules.
local ArenaService = require(ServerScriptService.Arena.ArenaService)

local StealService = {}

-- --- Tunables ----------------------------------------------------
-- Canonical: StealConfig (cooldown) + PromptConfig (distances).
-- Values preserved exactly.

-- Anti-spam: at most one steal request per player per window.
-- Rejections are cheap (no mutation), so this only blunts
-- RemoteEvent/prompt spam, never legitimate play.
local STEAL_COOLDOWN_S = StealConfig.Cooldown

-- --- Internal state ----------------------------------------------

local playerServiceRef: any = nil
local _lastAttempt: { [number]: number } = {}
local _touchedConnected: { [BasePart]: boolean } = {}
local _collectorBaseId: { [BasePart]: string } = {}

-- --- Small helpers -------------------------------------------------

local function _playerFromHit(hit: Instance): Player?
	local node: Instance? = hit
	while node do
		local player = Players:GetPlayerFromCharacter(node)
		if player then
			return player
		end
		node = node.Parent
	end
	return nil
end

local function _characterHrp(player: Player): BasePart?
	local character = player.Character
	if not character then
		return nil
	end
	local hrp = character:FindFirstChild('HumanoidRootPart')
	if hrp and hrp:IsA('BasePart') then
		return hrp
	end
	return nil
end

local function _maxDistanceFor(kind: string): number
	if kind == SlotType.OccupantKind.Animal then
		return PromptConfig.AnimalPickup.MaxActivationDistance
	end
	return PromptConfig.CarryMaxDistance
end

local function _resolveRecord(kind: string, uniqueId: string): any?
	if kind == SlotType.OccupantKind.Egg then
		return SpawnService.GetEgg(uniqueId)
	elseif kind == SlotType.OccupantKind.Animal then
		return AnimalService.Get(uniqueId)
	end
	return nil
end

local function _thiefCollector(thiefUserId: number): (any?, BasePart?)
	local base = BaseService.GetBaseByOwner(thiefUserId)
	if not base then
		return nil, nil
	end
	local collector = base.collector
	if typeof(collector) ~= 'Instance' or not (collector :: Instance):IsA('BasePart') then
		return base, nil
	end
	return base, collector :: BasePart
end

local function _notify(player: Player?, kind: string, text: string)
	if playerServiceRef and playerServiceRef.Notify and player then
		pcall(playerServiceRef.Notify, player, kind, text)
	end
end

-- Map a CanSteal rejection code to one canonical WarningMessages
-- catalog id (wording only — validation order lives in CanSteal).
-- Internal codes (invalid-player, rate-limited) never reach here
-- with a notification: the former isn't a real player, the latter
-- is handled at the TrySteal call site.
local function _stealRejectReason(code: any): string
	if code == 'base-locked' then
		return 'Steal_BaseLocked'
	elseif code == 'no-destination' then
		return 'Steal_BaseFull'
	elseif code == 'own-object' then
		return 'Steal_OwnAnimal'
	elseif code == 'already-carrying' then
		return 'Steal_AlreadyCarrying'
	elseif code == 'too-far' then
		return 'Steal_TooFar'
	elseif code == 'in-progress' or code == 'already-carried' or code == 'slot-race' or code == 'raid-locked' then
		return 'Steal_TargetBusy'
	elseif
		code == 'target-gone'
		or code == 'invalid-target'
		or code == 'not-stealable-state'
		or code == 'not-slotted'
		or code == 'owner-mismatch'
	then
		return 'Steal_TargetGone'
	end
	return 'General_Generic'
end

-- Display name for feedback text: server-authoritative record or
-- model name, kind-aware fallback. Never a client value.
local function _stealDisplayName(record: any, kindStr: string?): string
	local name: string? = nil
	pcall(function()
		name = record and record.displayName or nil
	end)
	if type(name) ~= 'string' or name == '' then
		pcall(function()
			name = record and record.model and record.model.Name or nil
		end)
	end
	if type(name) ~= 'string' or name == '' then
		name = if kindStr == SlotType.OccupantKind.Egg then 'Egg' else 'Animal'
	end
	return name :: string
end

-- Authoritative rarity for feedback coloring: runtime record
-- fields first (animal `.rarity`, egg `.rarity`, profile-style
-- `.Rarity`), nil when unknown (formatter falls back to plain).
-- Never a client value.
local function _stealRarity(record: any): string?
	local rarity: string? = nil
	pcall(function()
		local r = record and (record.rarity or record.Rarity) or nil
		if type(r) == 'string' and r ~= '' then
			rarity = r
		end
	end)
	return rarity
end

-- Victim robbery message: "<ThiefName> stole your <AnimalName>!"
-- Server-authoritative thief Name + record name/rarity (never
-- client values); the formatter escapes everything before
-- wrapping, so names can never inject markup. Danger-red
-- surrounding copy, rarity-colored entity. Plain-text fallback
-- if formatting ever fails (never silent, never markup).
local function _victimRobberyTextFor(thiefName: string, record: any, kindStr: string?): string
	local built: string? = nil
	pcall(function()
		local name = thiefName
		if type(name) ~= 'string' or name == '' then
			name = 'Someone'
		end
		built = RichTextFormatter.Danger(name .. ' stole your ')
			.. RichTextFormatter.Entity(_stealDisplayName(record, kindStr), _stealRarity(record), 'Animal')
			.. RichTextFormatter.Danger('!')
	end)
	if type(built) ~= 'string' or built == '' then
		return 'One of your objects was stolen!'
	end
	return built :: string
end

local function _victimRobberyText(thief: Player?, record: any, kindStr: string?): string
	local thiefName: string = 'Someone'
	pcall(function()
		if typeof(thief) == 'Instance' and (thief :: Instance):IsA('Player') then
			thiefName = (thief :: Player).Name
		end
	end)
	return _victimRobberyTextFor(thiefName, record, kindStr)
end

-- TEST-ONLY seam: build the victim robbery text for explicit
-- values through the REAL formatter path (no services). Lets
-- specs assert thief inclusion, rarity coloring, and markup
-- escaping without staging a steal.
function StealService._TestVictimText(thiefName: string, animalName: string, rarity: string?): string
	return _victimRobberyTextFor(thiefName, { displayName = animalName, rarity = rarity }, SlotType.OccupantKind.Animal)
end

local function _push(player: Player?)
	if playerServiceRef and playerServiceRef.PushState and player then
		pcall(function()
			playerServiceRef.PushState(player, BaseService.Snapshot(player.UserId))
		end)
	end
end

-- Owner robbery alert: plays ServerStorage.Assets.Sfx.Stealing
-- FOR THE ROBBED OWNER ONLY, immediately after a steal is
-- successfully reserved. The clone is parented to the owner's
-- PlayerGui — a server-parented PlayerGui child replicates to
-- that client alone, so the thief and bystanders hear nothing.
-- Never throws; silent no-op when the owner is offline, the
-- asset is missing/malformed, or the call happens outside a
-- successful steal start (invalid steals never reach here, so
-- they can never trigger the sound — exactly once per success).
local function _playStealSfxForOwner(ownerId: number)
	pcall(function()
		if type(ownerId) ~= 'number' then
			return
		end
		local owner = Players:GetPlayerByUserId(ownerId)
		if not owner then
			return
		end
		local playerGui = owner:FindFirstChildOfClass('PlayerGui')
		if not playerGui then
			return
		end
		local assets = ServerStorage:FindFirstChild('Assets')
		local sfxRoot = assets and assets:FindFirstChild('Sfx') or nil
		local template = sfxRoot and sfxRoot:FindFirstChild(AudioConfig.StealAlertSoundName) or nil
		if not template then
			Debug.Warn('ST', 'Stealing SFX asset missing — skipping robbery alert', {
				hasAssets = tostring(assets ~= nil),
				hasSfx = tostring(sfxRoot ~= nil),
			})
			return
		end
		local source: Sound? = nil
		if template:IsA('Sound') then
			source = template
		else
			local found = template:FindFirstChildWhichIsA('Sound', true)
			if found then
				source = found
			end
		end
		if not source or source.SoundId == '' then
			Debug.Warn('ST', 'Stealing SFX has no playable Sound — skipping robbery alert', {
				templateClass = template.ClassName,
			})
			return
		end
		local clone = source:Clone()
		clone.Name = 'StealAlert'
		clone.Looped = false
		clone.PlayOnRemove = false
		AudioGroups.AssignSfx(clone)
		clone.Parent = playerGui
		if DebugConfig.Audio.Enabled == true then
						Debug.Log('Audio', ('steal resolve=%s soundId=%s volume=%s parent=PlayerGui play=called'):format(
					tostring(AudioConfig.StealAlertSoundName),
					tostring((source :: Sound).SoundId),
					tostring((source :: Sound).Volume)
				))
		end
		pcall(function()
			(clone :: Sound):Play()
		end)
		local length = StealConfig.AlertFallbackCleanup
		local okLen, timeLength = pcall(function()
			return (clone :: Sound).TimeLength
		end)
		if okLen and type(timeLength) == 'number' and timeLength == timeLength and timeLength > 0 then
			length = timeLength + StealConfig.AlertCleanupPad
		end
		Debris:AddItem(clone, length)
		Debug.Log('ST', 'robbery alert played', { ownerId = tostring(ownerId) })
	end)
end

-- --- Public state queries (sweep/death guards) ---------------------

-- True when the (kind, id) object is currently steal-carried.
-- Scans the carry registry (rare calls only: leave sweeps,
-- restore paths — never hot).
function StealService.IsStolenRecord(kind: string, uniqueId: string): boolean
	local found = false
	CarryRegistry.ForEach(function(_uid: number, item: any)
		if found then
			return
		end
		if
			type(item) == 'table'
			and item.steal ~= nil
			and item.kind == kind
			and type(item.record) == 'table'
			and item.record.uniqueId == uniqueId
		then
			found = true
		end
	end)
	return found
end

-- True when this player's carry item is a steal in progress.
function StealService.IsStealCarry(playerOrUserId: any): boolean
	local item = CarryRegistry.Get(playerOrUserId)
	return item ~= nil and type(item) == 'table' and item.steal ~= nil
end

-- --- Init / wiring -------------------------------------------------

function StealService.SetPlayerService(svc: any)
	playerServiceRef = svc
end

function StealService.Init()
	CarryPrompts.SetStealPromptCallback(function(player: Player, occupantId: string, kind: string?)
		StealService.TrySteal(player, occupantId, kind)
	end)
	Debug.Log('ST', 'Init: steal callback wired (completion is touch-only, no prompt)')
end

-- One Touched connection per base collector (IncomeService
-- pattern). Idempotent: re-running never double-connects.
-- Touch only routes to TryComplete, which re-validates
-- everything (carry, ownership, distance) server-side.
function StealService.Start()
	for _, base in pairs(BaseService.GetAllBases()) do
		local collector = base and base.collector
		if
			typeof(collector) == 'Instance'
			and (collector :: Instance):IsA('BasePart')
			and not _touchedConnected[collector :: BasePart]
		then
			_touchedConnected[collector :: BasePart] = true
			_collectorBaseId[collector :: BasePart] = base.id;
			(collector :: BasePart).Touched:Connect(function(hit: Instance)
				local player = _playerFromHit(hit)
				if not player then
					return
				end
				if not StealService.IsStealCarry(player) then
					return
				end
				local thiefBase = BaseService.GetBaseByOwner(player.UserId)
				if not thiefBase or thiefBase.id ~= _collectorBaseId[collector :: BasePart] then
					return
				end
				StealService.TryComplete(player)
			end)
		end
	end
	Debug.Log('ST', 'Start: collector touch routing armed')
end

function StealService.ForgetPlayer(userId: number)
	_lastAttempt[userId] = nil
	_thiefSpeed[userId] = nil
end

-- --- Validation (pure, testable) ------------------------------------

-- Pure checks for a steal request. No mutation, no yields —
-- safe to call from tests and admin probes. `thiefPosOverride`
-- supplies the thief's position when no live character exists
-- (tests); otherwise the HRP is read from the live player.
-- Returns { ok = true, record, slot, ownerId } or
-- { ok = false, error = <code> }.
function StealService.CanSteal(
	thiefUserId: number,
	occupantId: string,
	kind: string?,
	thiefPosOverride: Vector3?
): { [string]: any }
	if type(thiefUserId) ~= 'number' or not Validation.IsValidPlayerUserId(thiefUserId) then
		return { ok = false, error = 'invalid-player' }
	end
	if type(occupantId) ~= 'string' or occupantId == '' then
		return { ok = false, error = 'invalid-target' }
	end
	if kind ~= SlotType.OccupantKind.Egg and kind ~= SlotType.OccupantKind.Animal then
		return { ok = false, error = 'wrong-kind' }
	end
	local kindStr: string = kind :: string
	if CarryRegistry.IsCarrying(thiefUserId) then
		return { ok = false, error = 'already-carrying' }
	end
	local record: any = _resolveRecord(kindStr, occupantId)
	if not record then
		return { ok = false, error = 'target-gone' }
	end
	if record._mutex then
		return { ok = false, error = 'in-progress' }
	end
	-- Arena raid lock (animals only): a fighter in an active
	-- raid cannot be stolen until the raid ends. Eggs never
	-- enter raids, so they skip this check.
	if kindStr == SlotType.OccupantKind.Animal and ArenaService.IsAnimalRaidLocked(occupantId) then
		return { ok = false, error = 'raid-locked' }
	end
	-- Stealable states only: resting on a slot. Anything
	-- carried, travelling, opening, or recovering is rejected.
	if kindStr == SlotType.OccupantKind.Egg then
		if record.state ~= 'Placed' then
			return { ok = false, error = 'not-stealable-state' }
		end
	else
		if record.state ~= 'Slotted' and record.state ~= 'Placed' then
			return { ok = false, error = 'not-stealable-state' }
		end
	end
	if record.carriedBy ~= nil or record.stolenBy ~= nil then
		return { ok = false, error = 'already-carried' }
	end
	if type(record.slotId) ~= 'string' then
		return { ok = false, error = 'not-slotted' }
	end
	local slot = SlotService._findSlotById(record.slotId)
	if not slot or not slot.part then
		return { ok = false, error = 'not-slotted' }
	end
	-- Arena stands are first-class slots: arena-team animals
	-- steal through this exact path (same lock, distance,
	-- and delivery rules). A Steal prompt is installed on
	-- arena occupants for non-owners, exactly like normal.
	if slot.state ~= SlotType.State.Occupied or slot.occupantId ~= record.uniqueId or slot.occupantKind ~= kindStr then
		return { ok = false, error = 'slot-race' }
	end
	-- Authoritative owner: the SLOT's owner (cross-checked
	-- against the record). Never any client-supplied id.
	local ownerId = slot.ownerUserId
	if not Validation.IsValidPlayerUserId(ownerId) then
		return { ok = false, error = 'target-gone' }
	end
	if record.ownerUserId ~= ownerId then
		return { ok = false, error = 'owner-mismatch' }
	end
	if ownerId == thiefUserId then
		-- Owners use normal grab; also guarantees the owner
		-- never passes a steal of their own object even via a
		-- forged request. CanSteal is pure (no mutation, no
		-- yields) and TrySteal mutates only after check.ok, so
		-- this rejection — like every CanSteal rejection —
		-- commits ZERO state: no reservation, no carry, no
		-- prompt or transaction side effects. Do not move this
		-- check below any mutating step.
		return { ok = false, error = 'own-object' }
	end
	-- Thief must own a base (delivery needs a collector).
	local thiefBase = BaseService.GetBaseByOwner(thiefUserId)
	if not thiefBase then
		return { ok = false, error = 'no-thief-base' }
	end
	-- Destination capacity BEFORE pickup: the thief must have
	-- a legally placeable slot RIGHT NOW (canonical
	-- Empty-only GetFreeSlot — the same primitive Place uses).
	-- A full base means no steal interaction exists. Checked
	-- again + reserved atomically at commit time below.
	local destProbe = SlotService.GetFreeSlot(thiefUserId)
	if not destProbe then
		return { ok = false, error = 'no-destination' }
	end
	-- Base Lock does NOT gate steal-start: anyone inside may pick
	-- the object up. The lock is an escape restriction enforced
	-- physically (locked lasers collide in the BaseLock_X group),
	-- so a thief cannot leave the locked base with the item —
	-- delivery stays unreachable while locked. Never re-add a
	-- locked-base rejection here.
	-- Server-side distance: the thief's HRP to the slot part.
	local thiefPos = thiefPosOverride
	if not thiefPos then
		local thiefPlayer = Players:GetPlayerByUserId(thiefUserId)
		local hrp = thiefPlayer and _characterHrp(thiefPlayer) or nil
		if hrp then
			thiefPos = hrp.Position
		end
	end
	if not thiefPos then
		return { ok = false, error = 'no-character' }
	end
	if ((thiefPos :: Vector3) - slot.part.Position).Magnitude > _maxDistanceFor(kindStr) then
		return { ok = false, error = 'too-far' }
	end
	local model = record.model
	if typeof(model) ~= 'Instance' or not (model :: Instance):IsA('Model') or (model :: Model).Parent == nil then
		return { ok = false, error = 'target-gone' }
	end
	if not (model :: Model).PrimaryPart then
		return { ok = false, error = 'target-gone' }
	end
	return { ok = true, record = record, slot = slot, ownerId = ownerId }
end

-- --- Steal start (atomic) ------------------------------------------

-- Thief walkspeed snapshots (pre-steal values, restored on every
-- steal exit). Relative slow: applied value is current *
-- StealSpeedMultiplier, so admin-set speeds survive the round trip.
-- Missing snapshot = never slowed = restore is a no-op (never
-- writes a guessed speed).
local _thiefSpeed: { [number]: number } = {}

local function _slowThiefForSteal(thiefUserId: number)
	if type(thiefUserId) ~= 'number' then
		return
	end
	if _thiefSpeed[thiefUserId] ~= nil then
		return
	end
	pcall(function()
		local player = Players:GetPlayerByUserId(thiefUserId)
		local character = if player ~= nil then player.Character else nil
		local humanoid = if character ~= nil then character:FindFirstChildOfClass('Humanoid') else nil
		if humanoid == nil then
			return
		end
		local current = (humanoid :: Humanoid).WalkSpeed
		if type(current) ~= 'number' or current ~= current or current <= 0 then
			return
		end
		_thiefSpeed[thiefUserId] = current
		local hum = humanoid :: Humanoid
		hum.WalkSpeed = current * StealConfig.StealSpeedMultiplier
	end)
end

local function _restoreThiefSpeed(thiefUserId: number)
	if type(thiefUserId) ~= 'number' then
		return
	end
	local snapshot = _thiefSpeed[thiefUserId]
	_thiefSpeed[thiefUserId] = nil
	if snapshot == nil then
		return
	end
	pcall(function()
		local player = Players:GetPlayerByUserId(thiefUserId)
		local character = if player ~= nil then player.Character else nil
		local humanoid = if character ~= nil then character:FindFirstChildOfClass('Humanoid') else nil
		if humanoid == nil then
			return
		end
		local hum = humanoid :: Humanoid
		hum.WalkSpeed = snapshot
	end)
end

-- Temporary STOLEN overhead on the stolen animal (animals
-- only — eggs carry no animal overhead). Presentation only:
-- the record's name/ownership never change. Guarded so a
-- missing model/gui can never break the steal transaction.
local function _applyStealPresentation(record: any, kindStr: string)
	pcall(function()
		if kindStr ~= SlotType.OccupantKind.Animal then
			return
		end
		AnimalOverhead.SetStolen(record, true)
	end)
end

local function _clearStealPresentation(record: any)
	pcall(function()
		AnimalOverhead.SetStolen(record, false)
	end)
end

-- Request: "I want to steal target X." The server resolves
-- everything else (owner, base, slot, type) — the client sends
-- only the target id + claimed kind, both re-validated here.
-- Returns { success = true } or { success = false, error }.
function StealService.TrySteal(player: Player, occupantId: string, kind: string?): { [string]: any }
	if not Validation.LivePlayer(player) then
		return { success = false, error = 'invalid-player' }
	end
	-- Death/reset lockout FIRST (before rate-limit or any
	-- state read): a dead/dying/respawning player has ZERO
	-- interaction authority. LivePlayer alone is insufficient
	-- (the Player instance survives death) — the CURRENT
	-- character must be live. Read fresh on every call.
	if not Validation.CanPlayerInteract(player) then
		return { success = false, error = 'player-not-live' }
	end
	local thiefId = player.UserId
	-- Rate-limit first: blunt prompt/RemoteEvent spam before
	-- spending any validation budget.
	local now = os.clock()
	if _lastAttempt[thiefId] and now - _lastAttempt[thiefId] < STEAL_COOLDOWN_S then
		pcall(NotificationService.NotifyWarning, player, 'Steal_Cooldown')
		return { success = false, error = 'rate-limited' }
	end
	_lastAttempt[thiefId] = now

	if type(occupantId) ~= 'string' or occupantId == '' then
		pcall(NotificationService.NotifyWarning, player, 'General_Generic')
		return { success = false, error = 'invalid-target' }
	end
	-- Pure validation first (ownership, lock, distance, state).
	-- Mutation below is synchronous with no yields, and the
	-- DemoteSlotToReserved reservation is the atomic point:
	-- exactly one of {B-steal, C-steal, A-grab, hatch} wins.
	-- Rejections notify through the canonical notification
	-- system (deterministic order lives in CanSteal; the mapping
	-- here only chooses the catalog id).
	local check = StealService.CanSteal(thiefId, occupantId, kind)
	if not check.ok then
		pcall(NotificationService.NotifyWarning, player, _stealRejectReason(check.error))
		return { success = false, error = check.error }
	end
	local kindStr: string = kind :: string
	local record: any = check.record
	local slot: any = check.slot
	local ownerId: number = check.ownerId
	local thiefBase = BaseService.GetBaseByOwner(thiefId)
	if not thiefBase then
		pcall(NotificationService.NotifyWarning, player, 'General_Generic')
		return { success = false, error = 'no-thief-base' }
	end
	local model = record.model

	-- ATOMIC RESERVATION: Occupied -> Reserved. Every loser
	-- fails here with 'slot-race'. No yields before or during,
	-- and CarryController.Start below is yield-free, so nothing
	-- can interleave between reservation and carry attach.
	record._mutex = true
	if not SlotService.DemoteSlotToReserved(slot.id) then
		record._mutex = false
		return { success = false, error = 'slot-race' }
	end
	-- Destination reservation, SAME atomic block: the thief's
	-- free slot is Reserved now, so two concurrent steals can
	-- never both commit into one destination, and a steal can
	-- never strand its carrier with nowhere legal to deliver.
	-- Empty-state is re-checked because ReserveSlot is a
	-- no-op success on already-Reserved slots (that path
	-- belongs to same-slot returns, never here).
	local destSlotId: string? = nil
	local function _failStealStart(err: string): { [string]: any }
		if type(destSlotId) == 'string' then
			SlotService.ReleaseSlot(destSlotId)
			destSlotId = nil
		end
		SlotService.OccupySlot(slot.id, record.uniqueId, kindStr)
		if kindStr == SlotType.OccupantKind.Egg then
			record.state = 'Placed'
		else
			record.state = 'Slotted'
		end
		record.carriedBy = nil
		record.originalSlotId = nil
		record.stolenBy = nil
		record._mutex = false
		return { success = false, error = err }
	end
	do
		local destSlot = SlotService.GetFreeSlot(thiefId)
		if not destSlot or destSlot.state ~= SlotType.State.Empty then
			pcall(NotificationService.NotifyWarning, player, 'Steal_BaseFull')
			return _failStealStart('no-destination')
		end
		if not SlotService.ReserveSlot(destSlot.id) then
			pcall(NotificationService.NotifyWarning, player, 'Steal_BaseFull')
			return _failStealStart('no-destination')
		end
		destSlotId = destSlot.id
	end

	if kindStr == SlotType.OccupantKind.Egg then
		record.state = 'Opening'
	else
		record.state = 'Carried'
	end
	record.carriedBy = thiefId
	record.originalSlotId = slot.id
	record.stolenBy = thiefId
	record.controller = nil
	record.controllerType = nil

	local character = player.Character
	local okStart, controller = pcall(CarryController.Start, record, thiefId, character, player)
	if not okStart or controller == nil then
		Debug.Warn('ST', 'TrySteal: carry attach failed, reservation restored', {
			uniqueId = tostring(record.uniqueId),
		})
		return _failStealStart('carry-failed')
	end
	record.controllerType = 'Carry'
	record.controller = controller
	if kindStr == SlotType.OccupantKind.Egg then
		StandPresentation.Unbind(model)
	end

	local okReg = CarryRegistry.Set(thiefId, {
		kind = kindStr,
		record = record,
		originalSlotId = slot.id,
		startedAt = os.clock(),
		steal = {
			originalOwnerUserId = ownerId,
			originalBaseId = slot.baseId,
			-- Destination capacity, reserved atomically at
			-- steal start (see above). Completion delivers
			-- into THIS slot; rollback releases it.
			destSlotId = destSlotId,
			-- Character identity: the live character this
			-- steal was attached to. Completion requires
			-- player.Character to STILL be this instance, so
			-- a respawned character can never continue (or
			-- complete) a pre-death transaction. UserId alone
			-- survives respawns, so it cannot do this job.
			carryCharacter = character,
		},
	})
	if not okReg then
		pcall(CarryController.Stop, controller)
		record.controller = nil
		record.controllerType = nil
		return _failStealStart('carry-failed')
	end
	-- Thief slow: snapshot + multiplier from the steal commit
	-- until every exit below restores it.
	_slowThiefForSteal(thiefId)
	-- Stolen look: the animal reads STOLEN (red, name-only)
	-- until delivery or rollback restores it.
	_applyStealPresentation(record, kindStr)

	-- Carried models show no prompts and the thief gets NO
	-- Place prompts (steal items can never be placed) and NO
	-- Deliver prompt either: completion is touch-only — the
	-- thief physically touches their own Collector.
	CarryPrompts.RemovePromptsFromModel(model)
	CarryPrompts.DisablePickupHatchPromptsForBase(thiefBase)

	_push(player)
	-- Success ONLY after the steal-start commit above (victim
	-- slot demoted, destination reserved, carry attached). The
	-- owner robbery alert + SFX below are preserved untouched.
	pcall(
		NotificationService.NotifySuccess,
		player,
		'Steal_Success',
		{ AnimalName = _stealDisplayName(record, kindStr), Rarity = _stealRarity(record) }
	)
	local ownerPlayer = Players:GetPlayerByUserId(ownerId)
	if ownerPlayer then
		_notify(ownerPlayer, 'Warning', _victimRobberyText(player, record, kindStr))
		_playStealSfxForOwner(ownerId)
		_push(ownerPlayer)
	else
		-- Owner offline: nobody to alert. The SFX is strictly
		-- per successful steal start, never on failure paths
		-- (all of them returned above).
		Debug.Log('ST', 'owner offline, robbery alert skipped', { ownerId = tostring(ownerId) })
	end
	record._mutex = false
	Debug.Log('ST', 'steal started', {
		kind = kindStr,
		uniqueId = tostring(record.uniqueId),
		thief = tostring(thiefId),
		owner = tostring(ownerId),
	})
	return { success = true }
end

-- --- Collector completion (atomic transfer) ------------------------

-- The thief physically touched their OWN collector while
-- steal-carrying. This is the ONLY completion path (touch-only,
-- no prompt, no E press). On success the profile record moves
-- A -> B (same Id, full data preserved) and the object is
-- seated in B's free slot. The object is never placed before
-- the profile moves and the profile never moves without a
-- reserved destination: no lost items, no overwrites of
-- occupied slots. Repeat touches are safe: the carry entry is
-- cleared on success, so only the first touch can transfer.
function StealService.TryComplete(player: Player): { [string]: any }
	if not Validation.LivePlayer(player) then
		return { success = false, error = 'invalid-player' }
	end
	-- Dead/dying/respawning players complete nothing — not
	-- even a legitimately carried steal. Death rollback (via
	-- the Died hook) owns the object from here.
	if not Validation.CanPlayerInteract(player) then
		return { success = false, error = 'player-not-live' }
	end
	local thiefId = player.UserId
	local item = CarryRegistry.Get(thiefId)
	if not item or type(item) ~= 'table' or item.steal == nil then
		return { success = false, error = 'not-a-steal' }
	end
	-- Character identity: the completing character must be the
	-- SAME instance the steal attached to. A respawned
	-- character (same UserId, new Model) can never finish a
	-- pre-death transaction — it rolls back instead.
	if player.Character == nil or player.Character ~= item.steal.carryCharacter then
		StealService.RollbackCarried(thiefId, 'character-changed')
		return { success = false, error = 'character-changed' }
	end
	local kindStr: string = item.kind
	local record: any = item.record
	if type(record) ~= 'table' or type(record.uniqueId) ~= 'string' then
		return { success = false, error = 'target-gone' }
	end
	if record._mutex then
		return { success = false, error = 'in-progress' }
	end
	-- Liveness: the runtime record must still be THE record
	-- (a replacement sharing a slot can never be transferred).
	local live = _resolveRecord(kindStr, record.uniqueId)
	if live ~= record then
		return { success = false, error = 'target-gone' }
	end
	local model = record.model
	if typeof(model) ~= 'Instance' or (model :: Model).Parent == nil then
		-- Model destroyed mid-carry: cancel cleanly rather
		-- than transferring a ghost.
		StealService.RollbackCarried(thiefId, 'target-destroyed')
		return { success = false, error = 'target-gone' }
	end
	local thiefBase, collector = _thiefCollector(thiefId)
	if not thiefBase then
		return { success = false, error = 'no-thief-base' }
	end
	if not collector then
		return { success = false, error = 'no-collector' }
	end
	-- Server-side proximity: HRP to the collector. Neither the
	-- prompt range nor Touched alone is the authority.
	local hrp = _characterHrp(player)
	if not hrp then
		return { success = false, error = 'no-character' }
	end
	local deliverRadius = (collector :: BasePart).Size.Magnitude / 2 + PromptConfig.CarryMaxDistance
	if (hrp.Position - (collector :: BasePart).Position).Magnitude > deliverRadius then
		return { success = false, error = 'too-far-from-collector' }
	end
	local origOwner = item.steal.originalOwnerUserId
	if type(origOwner) ~= 'number' or origOwner == thiefId then
		return { success = false, error = 'owner-mismatch' }
	end
	if record.ownerUserId ~= origOwner then
		return { success = false, error = 'owner-mismatch' }
	end
	-- Destination: the slot RESERVED at steal start is used
	-- first (capacity was proven then, not now). Fallback is a
	-- fresh Empty reserve — still atomic via OccupySlot below,
	-- so two completions can never share one destination.
	-- Never overwrites, never orphans.
	local fresh: any? = nil
	do
		local reservedId = item.steal.destSlotId
		if type(reservedId) == 'string' then
			local reserved = SlotService._findSlotById(reservedId)
			if reserved and reserved.state == SlotType.State.Reserved and reserved.ownerUserId == thiefId then
				fresh = reserved
			else
				Debug.Warn('ST', 'TryComplete: reserved destination lost, falling back to fresh reserve', {
					uniqueId = tostring(record.uniqueId),
					destSlotId = tostring(reservedId),
				})
			end
		end
		if not fresh then
			local candidate = SlotService.GetFreeSlot(thiefId)
			if candidate and candidate.state == SlotType.State.Empty and SlotService.ReserveSlot(candidate.id) then
				fresh = candidate
				item.steal.destSlotId = candidate.id
			end
		end
	end
	if not fresh then
		pcall(NotificationService.NotifyWarning, player, 'Steal_BaseFull')
		_push(player)
		local noSlotOwner = Players:GetPlayerByUserId(origOwner)
		if noSlotOwner then
			_push(noSlotOwner)
		end
		return { success = false, error = 'no-slot' }
	end
	record._mutex = true
	local function _failComplete(err: string): { [string]: any }
		SlotService.ReleaseSlot(fresh.id)
		record._mutex = false
		-- Failed completion still changed shared state (fresh
		-- reservation released above): push both sides so no
		-- client keeps a stale Occupied view of a slot that is
		-- now Empty (stale menus on empty slots).
		_push(player)
		local failOwner = Players:GetPlayerByUserId(origOwner)
		if failOwner then
			_push(failOwner)
		end
		return { success = false, error = err }
	end

	-- Snapshot A's canonical profile record BEFORE removal
	-- (Id + full progression preserved exactly; SlotId is the
	-- only field that legitimately changes).
	local snapshot: any? = nil
	if playerServiceRef then
		if kindStr == SlotType.OccupantKind.Egg and playerServiceRef.GetEggs then
			for _, rec in ipairs(playerServiceRef.GetEggs(origOwner)) do
				if type(rec) == 'table' and rec.Id == record.uniqueId then
					snapshot = {
						Rarity = rec.Rarity,
						Mutations = rec.Mutations,
						Trait = rec.Trait,
					}
					break
				end
			end
		elseif kindStr == SlotType.OccupantKind.Animal and playerServiceRef.GetAnimals then
			for _, rec in ipairs(playerServiceRef.GetAnimals(origOwner)) do
				if type(rec) == 'table' and rec.Id == record.uniqueId then
					snapshot = {
						DefId = rec.DefId,
						Level = rec.Level,
						XP = rec.XP,
						CashPool = rec.CashPool,
						Trait = rec.Trait,
						Mutations = rec.Mutations,
					}
					break
				end
			end
		end
	end
	if not snapshot then
		Debug.Warn('ST', 'TryComplete: original profile record missing', {
			uniqueId = tostring(record.uniqueId),
		})
		return _failComplete('record-gone')
	end

	-- Staged transfer: Add(B) BEFORE Remove(A). Remove(A)
	-- settles A's accrued pool to A's money per global removal
	-- policy (same as sell); B's record carries the pool value
	-- forward so progression is preserved exactly.
	--
	-- ORDERING (corruption fix): the destination Occupy lands
	-- FIRST, before either profile moves. The old order
	-- (profiles → release orig → occupy fresh) left a
	-- split-brain when Occupy failed: B's profile owned the Id
	-- while the runtime record still named A, was still
	-- carried, and the source slot was already Empty. That
	-- state rejects upgrades on both sides (A sees
	-- carried/not-owner, B sees not-owner), strands B's
	-- profile SlotId on a Reserved slot, and mis-seats any
	-- later rollback onto the wrong base. With occupy-first, a
	-- failed seat mutates NOTHING (profiles intact, source
	-- still Reserved, carry kept): retryable, never split.
	local function _seatDestination(): boolean
		return SlotService.OccupySlot(fresh.id, record.uniqueId, kindStr)
	end
	if not _seatDestination() then
		Debug.Warn('ST', 'TryComplete: destination occupy failed (nothing moved, carry kept)', {
			uniqueId = tostring(record.uniqueId),
			slotId = tostring(fresh.id),
		})
		return _failComplete('slot-race')
	end
	local added = false
	if playerServiceRef then
		if kindStr == SlotType.OccupantKind.Egg then
			added = playerServiceRef.AddEgg(thiefId, fresh.id, snapshot.Rarity, record.uniqueId, {
				Mutations = snapshot.Mutations,
				Trait = snapshot.Trait,
			})
		else
			added = playerServiceRef.AddAnimal(thiefId, fresh.id, snapshot.DefId, record.uniqueId, {
				Level = snapshot.Level,
				XP = snapshot.XP,
				CashPool = snapshot.CashPool,
				Trait = snapshot.Trait,
				Mutations = snapshot.Mutations,
			})
		end
	end
	if not added then
		Debug.Warn('ST', 'TryComplete: Add to thief profile failed', {
			uniqueId = tostring(record.uniqueId),
		})
		return _failComplete('transfer-failed')
	end
	local removed = false
	if playerServiceRef then
		if kindStr == SlotType.OccupantKind.Egg then
			removed = playerServiceRef.RemoveEgg(origOwner, record.uniqueId)
		else
			removed = playerServiceRef.RemoveAnimal(origOwner, record.uniqueId)
		end
	end
	if not removed then
		-- Undo the Add before surfacing: A still owns the
		-- record, so B must not keep a copy. Carry continues.
		if playerServiceRef then
			if kindStr == SlotType.OccupantKind.Egg then
				playerServiceRef.RemoveEgg(thiefId, record.uniqueId)
			else
				playerServiceRef.RemoveAnimal(thiefId, record.uniqueId)
			end
		end
		Debug.Warn('ST', 'TryComplete: Remove from owner failed, transfer undone', {
			uniqueId = tostring(record.uniqueId),
		})
		return _failComplete('transfer-failed')
	end

	-- Profile moved. Release the original reservation, then
	-- seat the object in the ALREADY-OCCUPIED slot (occupied
	-- above before the profiles moved, so a seat failure can
	-- never strand a moved profile). Slot failures from here
	-- keep the (moved) profile + live carry: retryable, never
	-- lost, never duplicated.
	local origSlotId: string? = item.originalSlotId
	if type(origSlotId) == 'string' then
		local okRelease = SlotService.ReleaseSlot(origSlotId)
		if not okRelease then
			Debug.Warn('ST', 'TryComplete: original slot release failed (non-fatal)', {
				slotId = tostring(origSlotId),
			})
		end
	end

	-- Stop the carry, flip runtime ownership, seat the model.
	if record.controller and CarryController.IsRunning(record.controller) then
		pcall(CarryController.Stop, record.controller)
	end
	record.controller = nil
	record.controllerType = nil
	record.ownerUserId = thiefId
	record.slotId = fresh.id
	record.originalSlotId = nil
	record.carriedBy = nil
	record.stolenBy = nil
	if kindStr == SlotType.OccupantKind.Egg then
		record.state = 'Placed'
	else
		record.state = 'Slotted'
	end
	local freshSlot = SlotService._findSlotById(fresh.id)
	if freshSlot then
		if kindStr == SlotType.OccupantKind.Egg then
			local eggModel = record.model
			if typeof(eggModel) == 'Instance' and (eggModel :: Instance).Parent ~= nil then
				local container = SpawnService.GetActiveContainer()
				if container and (eggModel :: Model).Parent ~= container then
					(eggModel :: Model).Parent = container
				end
			end
			HoverMath.Settle(record, freshSlot)
			StandPresentation.Bind(record.model, SlotType.OccupantKind.Egg)
			SpawnService.InstallHatchPrompt(record, freshSlot, thiefId)
		else
			AnimalService.SettleModelAtSlot(record, freshSlot)
		end
	end
	-- Post-commit reconcile, slot-scoped through the canonical
	-- SlotService display pipeline (pool attribute + stand
	-- upgrade readout), AFTER the runtime record is final:
	--   * destination: OccupySlot above fired while
	--     record.ownerUserId still named the ORIGINAL owner, so
	--     the stand readout painted the empty state for a slot
	--     that is in fact occupied — repaint it now that the
	--     record names the thief;
	--   * source: ReleaseSlot(Reserved -> Empty) now notifies on
	--     its own, but re-derive it here too so the empty state
	--     is explicit even if the transition hook ever changes.
	-- Same call stack, deterministic, no polling, no scans.
	if type(origSlotId) == 'string' then
		SlotService.RefreshDisplays(origSlotId)
	end
	SlotService.RefreshDisplays(fresh.id)
	CarryRegistry.Clear(thiefId)
	CarryPrompts.EnablePickupHatchPromptsForBase(thiefBase)
	record._mutex = false

	_push(player)
	local ownerPlayer = Players:GetPlayerByUserId(origOwner)
	if ownerPlayer then
		_push(ownerPlayer)
		_notify(ownerPlayer, 'Warning', _victimRobberyText(player, record, kindStr))
	end
	-- Success ONLY after the delivery commit above (profile
	-- record moved A -> B, seated in the reserved slot). Owner
	-- alert above is preserved untouched.
	pcall(
		NotificationService.NotifySuccess,
		player,
		'Steal_DeliverySuccess',
		{ AnimalName = _stealDisplayName(record, kindStr), Rarity = _stealRarity(record) }
	)
	Debug.Log('ST', 'steal complete', {
		kind = kindStr,
		uniqueId = tostring(record.uniqueId),
		thief = tostring(thiefId),
		slotId = tostring(fresh.id),
	})
	-- Funnel: ownership transferred A -> B above (profile moved
	-- + seated). Attempts, prompts, and cooldowns never log.
	pcall(function()
		FunnelService:LogStep(player, 'Social', 'StealSucceeded', { kind = kindStr })
	end)
	-- Delivered: a normal owned animal again (normal name,
	-- normal labels) + normal thief speed.
	_clearStealPresentation(record)
	_restoreThiefSpeed(thiefId)
	return { success = true, slotId = fresh.id }
end

-- --- Rollback (cancel / death / leave / destroy) -------------------

-- Return a steal-carried object to its ORIGINAL owner.
-- The profile never moved, so this is runtime-only: re-occupy
-- the Reserved original slot (tier-1), else an empty slot on
-- the ORIGINAL owner's base with the record re-pointed
-- (tier-2), else a safe park with the record preserved
-- (tier-3: animals enter Recovering; eggs park Placed with no
-- slot — the owner-leave sweep is non-destructive by design,
-- so a rejoin respawns from the intact profile). Never
-- deletes, never duplicates, never strands in B's base.
function StealService.RollbackCarried(thiefUserId: number, reason: string?): { [string]: any }
	local item = CarryRegistry.Get(thiefUserId)
	if not item or type(item) ~= 'table' or item.steal == nil then
		return { success = false, error = 'not-a-steal' }
	end
	local kindStr: string = item.kind
	local record: any = item.record
	if type(record) ~= 'table' then
		CarryRegistry.Clear(thiefUserId)
		-- Carry changed: push so a stale suppression flag
		-- cannot stick on the client's filter.
		_push(Players:GetPlayerByUserId(thiefUserId))
		return { success = false, error = 'target-gone' }
	end
	local origOwner = item.steal.originalOwnerUserId
	local origSlotId: string? = item.originalSlotId
	Debug.Log('ST', '> RollbackCarried', {
		uniqueId = tostring(record.uniqueId),
		reason = tostring(reason),
	})

	if record.controller and CarryController.IsRunning(record.controller) then
		pcall(CarryController.Stop, record.controller)
	end
	record.controller = nil
	record.controllerType = nil
	CarryRegistry.Clear(thiefUserId)
	-- Release the destination reservation made at steal start
	-- (thief's slot returns to Empty). Guarded to Reserved-
	-- only: never touch an Occupied slot (completion owns its
	-- slot by the time the carry clears).
	do
		local destId = item.steal.destSlotId
		if type(destId) == 'string' then
			local dest = SlotService._findSlotById(destId)
			if dest and dest.state == SlotType.State.Reserved then
				SlotService.ReleaseSlot(destId)
			end
		end
	end
	-- Carry state changed: push immediately so the thief's
	-- client drops steal-suppression and restores normal
	-- prompt visibility (no stuck hidden UI on death/leave/
	-- cancel). No-op when the thief is gone.
	_push(Players:GetPlayerByUserId(thiefUserId))
	record.stolenBy = nil
	record.carriedBy = nil
	if kindStr == SlotType.OccupantKind.Egg then
		record.state = 'Placed'
	else
		record.state = 'Slotted'
	end
	-- No Deliver prompt ever existed (touch-only completion),
	-- so there is nothing prompt-side to tear down here.

	local function _seatAt(slot: any, slotOwnerId: number)
		record.slotId = slot.id
		record.originalSlotId = nil
		if kindStr == SlotType.OccupantKind.Egg then
			-- Re-home the model: the carry controller reparents
			-- it to a per-player carried folder, but egg models
			-- canonically live in ActiveEggs (same as every
			-- spawn/place path). Without this the recovered egg
			-- sits in a stale folder indefinitely.
			local model = record.model
			if typeof(model) == 'Instance' and (model :: Instance).Parent ~= nil then
				local container = SpawnService.GetActiveContainer()
				if container and (model :: Model).Parent ~= container then
					(model :: Model).Parent = container
				end
			end
			HoverMath.Settle(record, slot)
			StandPresentation.Bind(record.model, SlotType.OccupantKind.Egg)
			SpawnService.InstallHatchPrompt(record, slot, slotOwnerId)
		else
			AnimalService.SettleModelAtSlot(record, slot)
		end
	end

	-- The thief's own base had its prompts disabled at steal
	-- start: re-enable them now that the carry is over
	-- (otherwise the thief's base keeps dead affordances).
	-- Harmless when the base is gone.
	do
		local thiefBase = BaseService.GetBaseByOwner(thiefUserId)
		if thiefBase then
			CarryPrompts.RemovePlacePromptsForBase(thiefBase)
			CarryPrompts.EnablePickupHatchPromptsForBase(thiefBase)
		end
	end

	-- Push BOTH sides on every restored exit below: the
	-- owner's client must see the slot Occupied again (stale
	-- HUD/menu state is exactly the "returned but broken"
	-- report), and the thief's client must drop suppression.
	local function _pushRestored()
		_push(Players:GetPlayerByUserId(origOwner))
		_push(Players:GetPlayerByUserId(thiefUserId))
	end

	-- Post-commit guard: death landed AFTER the transfer
	-- committed (profile moved to the thief AND the destination
	-- slot occupied) but BEFORE seating finished (the animal
	-- settle yields one Heartbeat). Reverting now would strand
	-- a thief-owned record/profile on the original side and
	-- corrupt both. Finish the seating idempotently instead:
	-- re-seat, re-prompt, clear, push. Either the transfer
	-- fully commits or it safely rolls back — never half.
	if record.ownerUserId == thiefUserId and type(record.slotId) == 'string' then
		local dest = SlotService._findSlotById(record.slotId)
		if
			dest
			and dest.state == SlotType.State.Occupied
			and dest.occupantId == record.uniqueId
			and dest.occupantKind == kindStr
		then
			_seatAt(dest, thiefUserId)
			record._mutex = false
			-- No OccupySlot fired on this path (the slot was
			-- already occupied) — re-derive the destination
			-- presentation explicitly so the seat is never
			-- display-only.
			SlotService.RefreshDisplays(dest.id)
			_pushRestored()
			Debug.Log('ST', '< RollbackCarried: post-commit seating finished', {
				slotId = tostring(dest.id),
				reason = tostring(reason),
			})
			_clearStealPresentation(record)
			_restoreThiefSpeed(thiefUserId)
			return { success = true, completed = true }
		end
	end

	-- Tier-1: original slot still Reserved for the original owner.
	if type(origSlotId) == 'string' then
		local origSlot = SlotService._findSlotById(origSlotId)
		if
			origSlot
			and origSlot.state == SlotType.State.Reserved
			and origSlot.ownerUserId == origOwner
			and SlotService.OccupySlot(origSlotId, record.uniqueId, kindStr)
		then
			_seatAt(origSlot, origOwner)
			record._mutex = false
			-- OccupySlot above already notified, but the model
			-- seat + prompt install landed after it — re-derive
			-- the source presentation so seat and display agree.
			SlotService.RefreshDisplays(origSlot.id)
			_pushRestored()
			Debug.Log('ST', '< RollbackCarried: original slot', { slotId = tostring(origSlotId) })
			_clearStealPresentation(record)
			_restoreThiefSpeed(thiefUserId)
			return { success = true }
		end
	end
	-- Tier-2: any empty slot on the ORIGINAL owner's base (the
	-- record still points at its old SlotId, so re-point it —
	-- same policy as every other place path).
	local origBase = BaseService.GetBaseByOwner(origOwner)
	if origBase then
		for _, slot in pairs(origBase.slots) do
			if slot.state == SlotType.State.Empty then
				if SlotService.ReserveSlot(slot.id) and SlotService.OccupySlot(slot.id, record.uniqueId, kindStr) then
					if playerServiceRef then
						if kindStr == SlotType.OccupantKind.Egg then
							if not playerServiceRef.SetEggSlot(origOwner, record.uniqueId, slot.id) then
								Debug.Warn(
									'ST',
									'RollbackCarried: egg record re-point failed (runtime placed anyway)',
									{
										uniqueId = tostring(record.uniqueId),
									}
								)
							end
						else
							if not playerServiceRef.SetAnimalSlot(origOwner, record.uniqueId, slot.id) then
								Debug.Warn(
									'ST',
									'RollbackCarried: animal record re-point failed (runtime placed anyway)',
									{
										uniqueId = tostring(record.uniqueId),
									}
								)
							end
						end
					end
					_seatAt(slot, origOwner)
					record._mutex = false
					-- Same seat/display agreement as tier-1, for
					-- the fallback slot.
					SlotService.RefreshDisplays(slot.id)
					_pushRestored()
					Debug.Log('ST', '< RollbackCarried: owner fallback slot', { slotId = tostring(slot.id) })
					_clearStealPresentation(record)
					_restoreThiefSpeed(thiefUserId)
					return { success = true }
				end
			end
		end
	end
	-- Tier-3: nowhere to seat. Preserve everything, park
	-- visibly, loud warn. Animals use the existing Recovering
	-- pattern; eggs (no Recovering state) park Placed with no
	-- slot — Hatch/Grab require a slotId, the owner-leave
	-- sweep keeps the profile intact, and a rejoin respawns
	-- from it. Nothing is deleted or duplicated.
	record.slotId = nil
	record.originalSlotId = nil
	if kindStr == SlotType.OccupantKind.Animal then
		record.state = 'Recovering'
		local model = record.model
		if typeof(model) == 'Instance' and (model :: Instance).Parent ~= nil then
			local animalsRoot = game:GetService('Workspace'):FindFirstChild('Animals')
			local recovering = animalsRoot and animalsRoot:FindFirstChild('Recovering') or nil
			if not recovering and animalsRoot then
				recovering = Instance.new('Folder')
				recovering.Name = 'Recovering'
				recovering.Parent = animalsRoot
			end
			if recovering then
				(model :: Model).Parent = recovering
			end
			CarryPrompts.RemovePromptsFromModel(model)
		end
	else
		record.state = 'Placed'
		local model = record.model
		if typeof(model) == 'Instance' and (model :: Instance).Parent ~= nil then
			-- Same re-homing as the seated tiers: the model
			-- must not linger in a per-player carried folder.
			local container = SpawnService.GetActiveContainer()
			if container and (model :: Model).Parent ~= container then
				(model :: Model).Parent = container
			end
			CarryPrompts.RemovePromptsFromModel(model)
			-- Bind the idle wobble around the parked pose so
			-- presentation matches any other placed egg.
			StandPresentation.Bind(model, SlotType.OccupantKind.Egg)
		end
	end
	record._mutex = false
	_pushRestored()
	Debug.Warn('ST', 'RollbackCarried: tier-3 park, record preserved', {
		uniqueId = tostring(record.uniqueId),
		reason = tostring(reason),
	})
	_clearStealPresentation(record)
	_restoreThiefSpeed(thiefUserId)
	return { success = true, parked = true }
end

-- Death/leave hook helper: if this user is steal-carrying,
-- roll back and report true (caller must skip the generic
-- owner-assuming recover). False means "not a steal — run
-- the normal path".
function StealService.RollbackIfStealing(userId: number, reason: string?): boolean
	if type(userId) ~= 'number' then
		return false
	end
	if not StealService.IsStealCarry(userId) then
		return false
	end
	StealService.RollbackCarried(userId, reason)
	return true
end

-- Owner-side hook: if the (kind, id) object is currently
-- steal-carried by ANYONE, roll it back to its owner now and
-- report true. Used by owner-leave sweeps BEFORE base teardown
-- so the sequence is recover-then-sweep (never skip-and-strand):
-- the record lands home while its slot still exists, then the
-- normal non-destructive sweep (model destroyed, runtime
-- dropped, profile kept) leaves a clean rejoin. Without this,
-- an owner leaving mid-steal would strand the thief carrying
-- against a wiped base. False when no steal-carry matches.
function StealService.RollbackStolenTarget(kind: string, uniqueId: string, reason: string?): boolean
	if type(kind) ~= 'string' or type(uniqueId) ~= 'string' then
		return false
	end
	local thiefId: number? = nil
	CarryRegistry.ForEach(function(uid: number, item: any)
		if thiefId ~= nil then
			return
		end
		if
			type(item) == 'table'
			and item.steal ~= nil
			and item.kind == kind
			and type(item.record) == 'table'
			and item.record.uniqueId == uniqueId
		then
			thiefId = uid
		end
	end)
	if thiefId == nil then
		return false
	end
	StealService.RollbackCarried(thiefId, reason)
	return true
end

return table.freeze(StealService)
