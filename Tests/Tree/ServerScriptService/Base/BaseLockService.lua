--!strict
--!native
--[[
	Base.BaseLockService
	====================
	Server-authoritative Base Locking for the MAIN GAME. The
	SERVER owns lock state, timers, ownership checks, and
	collision behavior; the timer label is display-only.

	How the owner exemption works (Roblox CanCollide is
	global, so per-player filtering needs collision groups):
	  * Static geometry groups `BaseLock_1..6`, one per Base.
	  * Static character groups `BaseOwner_1..6`, one per Base.
	  * Matrix: `BaseLock_X` collides with Default (blocks
	    everyone) but NOT with `BaseOwner_X` (owner passes);
	    `BaseOwner_X` collides with everything else (owner keeps
	    normal world/player/other-lock collision). A player owns
	    at most one Base, so one owner-group per Base is exact —
	    Base_1's lock never exempts Base_2's owner and vice
	    versa, with all 6 Bases fully independent.
	  * On lock, the Base's laser/hitbox parts move into its
	    `BaseLock_X` group with CanCollide=true; on unlock they
	    return to Default with authored CanCollide restored.
	  * Owner characters move into their `BaseOwner_X` group
	    while they own a LOCKED Base (applied on CharacterAdded
	    so respawns keep it, plus DescendantAdded for late
	    accessories), and back to Default otherwise.

	No remotes: activation is server-side `Touched` on the
	Studio-authored `LazerButton.PressPart`, with the Base
	derived from the touched Instance and ownership read from
	BaseService (never the client). One Heartbeat loop drives
	all ≤6 timers. Locks are runtime-only (never persisted).

	Paid door access (Unlock Doors Developer Product) is a
	PER-PURCHASER grant, independent of the owner's lock
	state: a purchase opens the base immediately AND records
	the buyer, so the buyer keeps collision passthrough even
	if the owner re-locks afterwards. The owner can ALWAYS
	lock/unlock with the button; a purchase never disables
	owner controls and never transfers ownership. Grants
	clear only on base release/reassign (clean slate for the
	next owner).

	Requires BaseService (one-directional: BaseService never
	requires this module; ownership transitions arrive via
	HandleBaseAssigned/HandleBaseReleased, wired by bootstrap
	into BaseService's injector).
]]

local Players = game:GetService('Players')
local PhysicsService = game:GetService('PhysicsService')
local RunService = game:GetService('RunService')

local BaseLockConfig = require(script.Parent.Parent.Parent.ReplicatedStorage.Config.World.Bases).Lock
local Debug = require(script.Parent.Parent.Parent.ReplicatedStorage.Utility.Debug)
local BaseService = require(script.Parent.Parent.BaseService)
-- Canonical player-facing rejections. Leaf module — cycle-free.
local NotificationService = require(script.Parent.NotificationService)
local TutorialSignals = require(script.Parent.Parent.Tutorial.TutorialSignals)
-- Funnel analytics (leaf module — never gameplay-critical).
local FunnelService = require(script.Parent.Parent.FunnelService)
-- Presentation-only laser barrier animation (grow/retract on
-- transitions). Never decides state, never touches collision.
local LaserAnimation = require(script.Parent.LaserAnimation)

local BaseLockService = {}

export type LockRecord = {
	baseId: string,
	baseIndex: number,
	folder: Instance,
	button: BasePart?,
	label: TextLabel?,
	labelDefault: string?,
	laserParts: { BasePart },
	laserBaseline: { [BasePart]: { transparency: number, collide: boolean } },
	lockParts: { BasePart },
	locked: boolean,
	expiresAt: number,
	lastDebounce: number,
	lastLabelSecond: number?,
}

-- --- Internal state ----------------------------------------------

local _locks: { [string]: LockRecord } = {}
-- Purchased door-access grants (baseId -> { [userId] = true }).
-- A grant opens the base NOW (the purchase paid for openness)
-- and records the buyer so THEY keep collision passthrough
-- across later owner re-locks. It is intentionally separate
-- from rec.locked: the owner can always re-lock, and locking
-- never revokes a paid grant. Entries are per-base-lifetime
-- (no duration in the product config) and clear ONLY in
-- HandleBaseReleased (release / reassign / leave / wipe) —
-- never on timer expiry, button press, or manual Unlock.
-- Survives owner death/respawn (session state, not character
-- state); respawns re-derive the group via RefreshCharacter.
local _purchasedOpen: { [string]: { [number]: boolean } } = {}
local _heartbeatConn: RBXScriptConnection? = nil
local _charConns: { [number]: { RBXScriptConnection } } = {}
local _groupsReady = false
local _started = false
-- Lock-transition observers (DoorService paid-door prompts).
-- Callbacks receive { baseId: string, locked: boolean }.
-- Fired from Lock/Unlock, which cover button presses, timer
-- expiry, releases, and purchase grants. Never yields into
-- callers: each listener runs pcall'd.
local _lockListeners: { (any) -> () } = {}

-- Subscribe to lock transitions. Idempotent per function
-- (same fn registered twice runs once). Never throws.
function BaseLockService.SubscribeLockChanged(fn: (any) -> ())
	if type(fn) ~= 'function' then
		return
	end
	for _, existing in ipairs(_lockListeners) do
		if existing == fn then
			return
		end
	end
	_lockListeners[#_lockListeners + 1] = fn
end

local function _fireLockChanged(baseId: string, locked: boolean)
	for _, fn in ipairs(_lockListeners) do
		pcall(fn, { baseId = baseId, locked = locked })
	end
end

-- --- Collision groups ----------------------------------------------

local function _lockGroup(index: number): string
	return 'BaseLock_' .. tostring(index)
end

local function _ownerGroup(index: number): string
	return 'BaseOwner_' .. tostring(index)
end

-- Register all groups + the matrix exactly once. Static and
-- data-free: 6 lock groups, 6 owner groups, Default for
-- everyone else.
local function _ensureGroups(baseCount: number)
	if _groupsReady then
		return
	end
	_groupsReady = true
	for i = 1, baseCount do
		pcall(PhysicsService.RegisterCollisionGroup, PhysicsService, _lockGroup(i))
		pcall(PhysicsService.RegisterCollisionGroup, PhysicsService, _ownerGroup(i))
	end
	for i = 1, baseCount do
		-- Locked geometry blocks the default world (everyone
		-- not explicitly exempted).
		pcall(PhysicsService.CollisionGroupSetCollidable, PhysicsService, _lockGroup(i), 'Default', true)
		for j = 1, baseCount do
			-- Owner of THIS base passes; owners of other
			-- bases are still blocked here.
			pcall(PhysicsService.CollisionGroupSetCollidable, PhysicsService, _lockGroup(i), _ownerGroup(j), i ~= j)
		end
		-- Owner characters keep normal collision with the
		-- world and other players.
		pcall(PhysicsService.CollisionGroupSetCollidable, PhysicsService, _ownerGroup(i), 'Default', true)
		for j = 1, baseCount do
			if i ~= j then
				pcall(PhysicsService.CollisionGroupSetCollidable, PhysicsService, _ownerGroup(i), _ownerGroup(j), true)
			end
		end
	end
	Debug.Log('BL', 'collision groups ready', { baseCount = tostring(baseCount) })
end

-- --- Geometry discovery (Studio-authored, never created) -----------

local function _collectBaseParts(root: Instance?): { BasePart }
	local out: { BasePart } = {}
	if typeof(root) ~= 'Instance' then
		return out
	end
	for _, descendant in ipairs(root:GetDescendants()) do
		if descendant:IsA('BasePart') then
			out[#out + 1] = descendant
		end
	end
	return out
end

-- --- Character collision ---------------------------------------------

local function _setCharacterGroup(player: Player, group: string)
	local character = player.Character
	if not character then
		return
	end
	for _, descendant in ipairs(character:GetDescendants()) do
		if descendant:IsA('BasePart') then
			(descendant :: BasePart).CollisionGroup = group
		end
	end
end

local function _clearCharConns(userId: number)
	local list = _charConns[userId]
	if list then
		for _, conn in ipairs(list) do
			pcall(function()
				conn:Disconnect()
			end)
		end
	end
	_charConns[userId] = nil
end

-- The group this player's character belongs in RIGHT NOW:
-- their base's owner group while they own a LOCKED base, else
-- the owner group of a LOCKED base they hold purchased access
-- to (paid grant survives owner re-locks), else Default.
-- Ownership comes from BaseService; lock state from this
-- service. Never the client, never position.
local function _wantedGroup(userId: number): string
	local base = BaseService.GetBaseByOwner(userId)
	if base and type(base.index) == 'number' then
		local rec = _locks[base.id]
		if rec and rec.locked and base.ownerUserId == userId then
			return _ownerGroup(base.index)
		end
	end
	for baseId, holders in pairs(_purchasedOpen) do
		if holders[userId] == true then
			local granted: any = nil
			pcall(function()
				granted = BaseService.GetBaseById(baseId)
			end)
			if type(granted) == 'table' and type(granted.index) == 'number' then
				local rec = _locks[baseId]
				if rec and rec.locked then
					return _ownerGroup(granted.index)
				end
			end
		end
	end
	return 'Default'
end

-- Re-derive the collision group for every live purchaser of a
-- base (call after lock/unlock transitions and grants).
-- Never throws.
local function _refreshPurchasers(baseId: string)
	pcall(function()
		local holders = _purchasedOpen[baseId]
		if type(holders) ~= 'table' then
			return
		end
		for holderId in pairs(holders) do
			local holder: Player? = nil
			pcall(function()
				holder = Players:GetPlayerByUserId(holderId)
			end)
			if holder ~= nil then
				BaseLockService.RefreshCharacter(holder)
			end
		end
	end)
end

-- (Re)apply the correct group to a player's live character and
-- keep late-added parts (accessories, tools) in sync. Safe to
-- call on any transition; idempotent per character.
function BaseLockService.RefreshCharacter(player: Player?)
	if typeof(player) ~= 'Instance' or not (player :: Instance):IsA('Player') then
		return
	end
	local typed = player :: Player
	local userId = typed.UserId
	_clearCharConns(userId)
	local character = typed.Character
	if not character then
		return
	end
	_setCharacterGroup(typed, _wantedGroup(userId))
	local list: { RBXScriptConnection } = {}
	list[#list + 1] = character.DescendantAdded:Connect(function(descendant)
		if descendant:IsA('BasePart') then
			(descendant :: BasePart).CollisionGroup = _wantedGroup(userId)
		end
	end)
	list[#list + 1] = character.Destroying:Connect(function()
		_clearCharConns(userId)
	end)
	_charConns[userId] = list
end

function BaseLockService.ForgetPlayer(player: Player?)
	if typeof(player) ~= 'Instance' or not (player :: Instance):IsA('Player') then
		return
	end
	_clearCharConns((player :: Player).UserId)
end

-- --- Lock visuals + collision ------------------------------------------

-- Move lock geometry into (or out of) the base's lock group.
-- Unlocked parts return to Default with their AUTHORED
-- CanCollide (captured at registration), so unlocking never
-- invents physics state.
local function _applyGeometry(rec: LockRecord, locked: boolean)
	for _, part in ipairs(rec.lockParts) do
		if part.Parent ~= nil then
			if locked then
				part.CollisionGroup = _lockGroup(rec.baseIndex)
				part.CanCollide = true
			else
				part.CollisionGroup = 'Default'
				local baseline = rec.laserBaseline[part]
				part.CanCollide = baseline and baseline.collide or false
			end
		end
	end
	for _, part in ipairs(rec.laserParts) do
		if part.Parent ~= nil then
			local baseline = rec.laserBaseline[part]
			if locked then
				part.Transparency = 0
			elseif baseline then
				part.Transparency = baseline.transparency
			end
		end
	end
end

local function _setLabel(rec: LockRecord, text: string?)
	if rec.label and rec.label.Parent ~= nil then
		if text ~= nil then
			rec.label.Text = text
		elseif rec.labelDefault ~= nil then
			rec.label.Text = rec.labelDefault
		end
	end
end

-- --- Lock transitions ------------------------------------------------------

function BaseLockService.IsLocked(baseId: string): boolean
	local rec = _locks[baseId]
	return rec ~= nil and rec.locked == true
end

function BaseLockService.GetRemainingTime(baseId: string): number
	local rec = _locks[baseId]
	if not rec or not rec.locked then
		return 0
	end
	return math.max(0, rec.expiresAt - os.clock())
end

-- Whether ANY purchased door-access grant is held for a
-- base. Read by DoorService/tests. Grants never block the
-- owner button (see Lock/HandleButtonTouched).
function BaseLockService.IsPurchasedOpen(baseId: string): boolean
	if type(baseId) ~= 'string' then
		return false
	end
	local holders = _purchasedOpen[baseId]
	if type(holders) ~= 'table' then
		return false
	end
	for _ in pairs(holders) do
		return true
	end
	return false
end

-- Whether a specific player holds purchased door access to a
-- base (passthrough survives owner re-locks until base
-- release/reassign). Never throws.
function BaseLockService.HasPurchasedAccess(baseId: string, userId: number): boolean
	if type(baseId) ~= 'string' or type(userId) ~= 'number' then
		return false
	end
	local holders = _purchasedOpen[baseId]
	return type(holders) == 'table' and holders[userId] == true
end

-- Owner-validated lock. At most ONE timer per base, and with
-- RefreshOnPress disabled a press while already locked is a
-- no-op (false): the base cannot be relocked until the timer
-- hits 0 and the Heartbeat loop expires the lock. Applies
-- collision + visuals immediately, then re-syncs the owner's
-- character group (plus every paid grant-holder, who keeps
-- passthrough under the new lock). A purchased unlock NEVER
-- blocks this: paid access is a per-buyer grant, not an
-- owner-lock override, so the owner always retains lock
-- control and visitors cannot touch it (HandleButtonTouched
-- re-checks live ownership on every press; there is no lock
-- remote to exploit).
function BaseLockService.Lock(base: any): boolean
	if type(base) ~= 'table' or type(base.id) ~= 'string' then
		return false
	end
	local rec = _locks[base.id]
	if not rec then
		return false
	end
	if rec.locked and not BaseLockConfig.RefreshOnPress then
		return false
	end
	rec.locked = true
	rec.expiresAt = os.clock() + BaseLockConfig.LockDurationSeconds
	rec.lastLabelSecond = BaseLockConfig.LockDurationSeconds
	-- Paint the full duration immediately (same Heartbeat path
	-- would land within a frame, but the press deserves an
	-- instant response and tests shouldn't race the tick).
	_setLabel(rec, tostring(BaseLockConfig.LockDurationSeconds))
	_applyGeometry(rec, true)
	-- Presentation: lasers grow from the ground to authored size.
	LaserAnimation.SetLocked(rec.baseId, rec.laserParts, true)
	local ownerId = base.ownerUserId
	if type(ownerId) == 'number' then
		local player = Players:GetPlayerByUserId(ownerId)
		if player then
			BaseLockService.RefreshCharacter(player)
		end
	end
	-- Paid grant-holders keep passthrough under the fresh lock.
	_refreshPurchasers(base.id)
	Debug.Log('BL', 'locked', { baseId = base.id, expiresIn = tostring(BaseLockConfig.LockDurationSeconds) })
	_fireLockChanged(base.id, true)
	-- Funnel: first successful lock per session (repeat presses
	-- refresh the same lock — not separate milestones).
	if type(ownerId) == 'number' then
		pcall(function()
			local ownerPlayer: Player? = nil
			pcall(function()
				ownerPlayer = Players:GetPlayerByUserId(ownerId)
			end)
			if ownerPlayer then
				FunnelService:LogStep(ownerPlayer, 'Social', 'FirstBaseLocked', nil)
			end
		end)
	end
	return true
end

-- Full unlock sequence, server-side: state, geometry, visuals,
-- timer label, owner character group. Idempotent.
function BaseLockService.Unlock(baseId: string)
	local rec = _locks[baseId]
	if not rec or not rec.locked then
		return
	end
	rec.locked = false
	rec.expiresAt = 0
	rec.lastLabelSecond = nil
	_applyGeometry(rec, false)
	-- Presentation: lasers retract to the ground, bottom anchored.
	LaserAnimation.SetLocked(rec.baseId, rec.laserParts, false)
	_setLabel(rec, nil)
	-- The (possibly still present) owner drops back to Default;
	-- RefreshCharacter re-derives from live ownership anyway.
	local base = BaseService.GetBaseById(baseId)
	local ownerId = base and base.ownerUserId or nil
	if type(ownerId) == 'number' then
		local player = Players:GetPlayerByUserId(ownerId)
		if player then
			BaseLockService.RefreshCharacter(player)
		end
	end
	Debug.Log('BL', 'unlocked', { baseId = baseId })
	_fireLockChanged(baseId, false)
	-- Grant-holders fall back to their derived group (Default
	-- unless they own another locked base or hold access
	-- elsewhere).
	_refreshPurchasers(baseId)
end

-- Purchase-driven access grant (Unlock Doors Developer
-- Product): opens the base NOW and records the buyer so THEY
-- keep collision passthrough across later owner re-locks.
-- The owner can always re-lock afterwards — the grant is
-- per-buyer, never an owner-lock override, and never
-- ownership. Idempotent (repeat receipts re-insert the same
-- key). Clears only in HandleBaseReleased. Safe to call on
-- an already-open base (the grant still records: the buyer
-- paid for access). Never throws.
function BaseLockService.UnlockPurchased(baseId: string, purchaserUserId: number?)
	if type(baseId) ~= 'string' or baseId == '' then
		return
	end
	if type(purchaserUserId) == 'number' then
		local holders = _purchasedOpen[baseId]
		if type(holders) ~= 'table' then
			holders = {}
			_purchasedOpen[baseId] = holders
		end
		holders[purchaserUserId] = true
	end
	BaseLockService.Unlock(baseId)
	if type(purchaserUserId) == 'number' then
		local holder: Player? = nil
		pcall(function()
			holder = Players:GetPlayerByUserId(purchaserUserId :: number)
		end)
		if holder ~= nil then
			BaseLockService.RefreshCharacter(holder)
		end
	end
end

-- --- Button touch (server-side, owner-validated) -----------------------------

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

function BaseLockService.HandleButtonTouched(rec: LockRecord, hit: Instance)
	local now = os.clock()
	if now - rec.lastDebounce < BaseLockConfig.ButtonDebounceSeconds then
		return
	end
	local player = _playerFromHit(hit)
	if not player then
		return
	end
	rec.lastDebounce = now
	-- Ownership from BaseService, re-read live. Non-owner touches
	-- (including touches on an unowned/empty base, where
	-- ownerUserId is nil) are fully silent: no warning UI, no
	-- warning SFX, no state change — as if the button did not
	-- exist for that player.
	local base = BaseService.GetBaseById(rec.baseId)
	if not base or base.ownerUserId ~= player.UserId then
		Debug.Log('BL', 'button touch ignored (not owner)', {
			baseId = rec.baseId,
			userId = tostring(player.UserId),
		})
		return
	end
	-- Success ONLY when the lock state actually changed (Lock
	-- returns false on re-press without refresh — no toast for
	-- a no-op press). Purchased grants never block this path:
	-- the owner always retains lock control; buyers keep
	-- passthrough via their own grant. Duration rides along
	-- so the toast names the configured lock window.
	if BaseLockService.Lock(base) then
		pcall(NotificationService.NotifySuccess, player, 'Lock_Success', {
			Duration = BaseLockConfig.LockDurationSeconds,
		})
		-- Tutorial guide layer observes the committed lock (bus
		-- never throws; the lock itself is unaffected).
		pcall(TutorialSignals.Fire, 'BaseLocked', { UserId = player.UserId, BaseId = rec.baseId })
	end
end

-- --- Ownership transitions (wired via BaseService injector) -------------------

-- Fresh assignment carries no lock: make sure the new owner
-- isn't wearing a stale owner-group from a previous base.
function BaseLockService.HandleBaseAssigned(userId: number)
	local player = Players:GetPlayerByUserId(userId)
	if player then
		BaseLockService.RefreshCharacter(player)
	end
end

-- Release/leave/wipe: never leave a base locked, never leave
-- the previous owner exempt. The existing BaseService
-- lifecycle then proceeds with a clean slate. Also clears
-- all purchased-access grants: a new assignment starts with
-- a clean door slate (an old purchase does not haunt the
-- next owner, who can lock normally).
function BaseLockService.HandleBaseReleased(baseId: string)
	if type(baseId) == 'string' and baseId ~= '' then
		_purchasedOpen[baseId] = nil
	end
	BaseLockService.Unlock(baseId)
end

-- --- Central timer loop (ONE Heartbeat for all bases) --------------------------

-- Resolve the lock timer label for a base folder.
-- Canonical path: Base.LazerButton.BillboardGui.Timer
-- (BillboardGui directly under LazerButton). The legacy
-- shape (BillboardGui under LazerButton.PressPart) and the
-- legacy TestLabel name are accepted as fallbacks. Returns
-- nil when the Studio hierarchy lacks it (loud Warn at the
-- call site that needs it, never silent).
local function _resolveLabel(folder: Instance?): TextLabel?
	if typeof(folder) ~= 'Instance' then
		return nil
	end
	local lazerButton = folder:FindFirstChild('LazerButton')
	if lazerButton then
		-- Canonical: BillboardGui directly under LazerButton.
		local gui = lazerButton:FindFirstChild('BillboardGui')
		local label = gui and gui:FindFirstChild('Timer')
		if label and label:IsA('TextLabel') then
			return label
		end
	end
	local pressPart = lazerButton and lazerButton:FindFirstChild('PressPart', true) or nil
	if not (pressPart and pressPart:IsA('BasePart')) then
		-- No PressPart chain: fall back to a folder-wide legacy
		-- TestLabel search before giving up.
		if lazerButton then
			local legacy = lazerButton:FindFirstChild('TestLabel', true)
			if legacy and legacy:IsA('TextLabel') then
				return legacy
			end
		end
		return nil
	end
	local gui = pressPart:FindFirstChild('BillboardGui', true)
	local label = gui and gui:FindFirstChild('Timer', true)
		or pressPart:FindFirstChild('Timer', true)
		or gui and gui:FindFirstChild('TestLabel', true)
		or pressPart:FindFirstChild('TestLabel', true)
	if label and label:IsA('TextLabel') then
		return label
	end
	return nil
end

local function _update()
	local now = os.clock()
	for _, rec in pairs(_locks) do
		if rec.locked then
			local remaining = rec.expiresAt - now
			if remaining <= 0 then
				BaseLockService.Unlock(rec.baseId)
			else
				-- Re-resolve a dead/missing label (GUI replaced
				-- at runtime): one FindFirstChild chain only
				-- while locked-and-label-less, never hot.
				if rec.label == nil or rec.label.Parent == nil then
					local relabelled = _resolveLabel(rec.folder)
					if relabelled then
						rec.label = relabelled
						if rec.labelDefault == nil then
							rec.labelDefault = relabelled.Text
						end
						rec.lastLabelSecond = nil
					end
				end
				local second = math.ceil(remaining)
				if rec.lastLabelSecond ~= second then
					rec.lastLabelSecond = second
					_setLabel(rec, tostring(second))
				end
			end
		end
	end
end

-- --- Registration ---------------------------------------------------------------

local function _registerBase(base: any)
	if type(base) ~= 'table' or type(base.id) ~= 'string' or typeof(base.folder) ~= 'Instance' then
		return
	end
	if _locks[base.id] then
		return
	end
	local folder = base.folder :: Instance
	local rec: LockRecord = {
		baseId = base.id,
		baseIndex = base.index,
		folder = folder,
		button = nil,
		label = nil,
		labelDefault = nil,
		laserParts = {},
		laserBaseline = {},
		lockParts = {},
		locked = false,
		expiresAt = 0,
		lastDebounce = 0,
		lastLabelSecond = nil,
	}
	-- Button + timer label via the shared resolver (Timer
	-- canonical, TestLabel legacy). Missing pieces warn
	-- loudly here, never silently.
	do
		local lazerButton = folder:FindFirstChild('LazerButton')
		local pressPart = lazerButton and lazerButton:FindFirstChild('PressPart', true) or nil
		if pressPart and pressPart:IsA('BasePart') then
			rec.button = pressPart
		else
			Debug.Warn('BL', 'base has no LazerButton.PressPart; locking unavailable', { baseId = base.id })
		end
		local label = _resolveLabel(folder)
		if label then
			rec.label = label
			rec.labelDefault = label.Text
		else
			Debug.Warn('BL', 'base button has no BillboardGui/Timer TextLabel; lock timer will not display', {
				baseId = base.id,
			})
		end
	end
	-- Lasers: visual Parts named exactly "Part" under
	-- LazerDoor.Lazers; lock geometry = every BasePart under
	-- Lazers (Hitbox included). Transparency/CanCollide
	-- baselines captured once so unlock restores authored
	-- state instead of inventing it.
	local lazerDoor = folder:FindFirstChild('LazerDoor')
	local lazers = lazerDoor and lazerDoor:FindFirstChild('Lazers') or nil
	if lazers then
		for _, descendant in ipairs(lazers:GetDescendants()) do
			if descendant:IsA('BasePart') then
				local part = descendant :: BasePart
				rec.laserBaseline[part] = { transparency = part.Transparency, collide = part.CanCollide }
				rec.lockParts[#rec.lockParts + 1] = part
				if part.Name == 'Part' then
					rec.laserParts[#rec.laserParts + 1] = part
				end
			end
		end
	else
		Debug.Warn('BL', 'base has no LazerDoor.Lazers; laser lock degraded', { baseId = base.id })
	end
	-- Build hitbox: every BasePart under Build.Hitbox.
	local build = folder:FindFirstChild('Build')
	local hitbox = build and build:FindFirstChild('Hitbox') or nil
	if hitbox then
		for _, part in ipairs(_collectBaseParts(hitbox)) do
			if rec.laserBaseline[part] == nil then
				rec.laserBaseline[part] = { transparency = part.Transparency, collide = part.CanCollide }
			end
			rec.lockParts[#rec.lockParts + 1] = part
		end
	else
		Debug.Warn('BL', 'base has no Build.Hitbox; build lock degraded', { baseId = base.id })
	end
	_locks[base.id] = rec
	-- Clean initial state: unlocked, authored physics, labels
	-- at authored defaults. Lasers capture authored size once
	-- and snap retracted (locks are runtime-only — a fresh base
	-- always starts unlocked). No timers start here.
	_applyGeometry(rec, false)
	LaserAnimation.Register(rec.baseId, rec.laserParts)
	_setLabel(rec, nil)
	if rec.button then
		local captured = rec
		rec.button.Touched:Connect(function(hit)
			BaseLockService.HandleButtonTouched(captured, hit)
		end)
	end
	Debug.Log('BL', 'base registered', {
		baseId = base.id,
		lockParts = tostring(#rec.lockParts),
		laserParts = tostring(#rec.laserParts),
		hasButton = tostring(rec.button ~= nil),
	})
end

-- --- Lifecycle ---------------------------------------------------------------------

function BaseLockService.Init()
	if _started then
		return
	end
	_started = true
	local bases = BaseService.GetAllBases()
	local count = 0
	for _ in pairs(bases) do
		count += 1
	end
	_ensureGroups(math.max(count, 6))
	for _, base in pairs(bases) do
		_registerBase(base)
	end
	Players.PlayerAdded:Connect(function(player)
		player.CharacterAdded:Connect(function()
			-- Character raced assignment: wait a beat so
			-- ownership reads settle, then apply.
			task.defer(function()
				BaseLockService.RefreshCharacter(player)
			end)
		end)
	end)
	-- Existing players (Studio catch-up): same treatment.
	for _, player in ipairs(Players:GetPlayers()) do
		if player.Character then
			BaseLockService.RefreshCharacter(player)
		end
		player.CharacterAdded:Connect(function()
			task.defer(function()
				BaseLockService.RefreshCharacter(player)
			end)
		end)
	end
	Players.PlayerRemoving:Connect(function(player)
		BaseLockService.ForgetPlayer(player)
	end)
	_heartbeatConn = RunService.Heartbeat:Connect(_update)
	Debug.Log('BL', 'BaseLockService started', { bases = tostring(count) })
end

return table.freeze(BaseLockService)
