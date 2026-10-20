--!strict
--!native
--[[
	PlayerGrabService
	=================
	Server-side presentation: plays the authored Grab pose on a
	player's Character while the server has them committed to a
	carry, stops it the moment the carry ends.

	Source (never cloned, never re-authored, never hardcoded):
	  ServerStorage.Assets.Animations.Player.Grab [Animation]

	Authority model — the SAME feed as ResetProtectionService:
	  CarryRegistry (single source of truth for carries)
	        |
	        +-- OnChanged(userId)   (committed Set/Clear only)
	        v
	  PlayerGrabService.syncGrab(userId)
	        +-- registry has entry -> ensure ONE Grab track playing
	        +-- registry empty      -> stop + forget
	        v
	  Character.Humanoid.Animator (existing Animator, one
	  AnimationTrack per live Character; server tracks replicate
	  to all clients for free — the NPC-animal pattern in
	  AnimalService._loadAnimations).

	No per-service hooks: owned pickup, steal carry, and Egg
	carry all commit through CarryRegistry.Set, so all three
	share this lifecycle with zero drift.

	Blending (§2-§3): the track plays at Action4 priority, Looped,
	with a 0.1s fade in/out. Stock character locomotion runs at
	Idle (idle) / Movement (walk/run) — Action4 outranks both, so
	a correctly authored UPPER-BODY-ONLY Grab holds the arms
	raised while legs keep walking/running/jumping. Nothing here
	touches WalkSpeed, JumpPower, AutoRotate, Anchoring, or
	CFrames — locomotion is entirely the Humanoid's business.
	!! Inspection gap (§19): ServerStorage assets are
	Studio-authored and not in this repo, so the Grab
	keyframes could not be verified here. If a Studio check
	shows the legs freezing, the asset carries lower-body
	tracks: re-author Grab without them (preferred) or lower
	GRAB_PRIORITY below. Do NOT "fix" it by anchoring/CFrame.

	Stale-transaction safety (§8): stop is driven ONLY by
	"registry empty / character invalid" — never by a per-tx
	callback. T100 ending while T101 is live leaves Grab
	playing; a late T100 cleanup has no handle to stop T101.

	One track per Character (§5): entries are keyed by userId
	and validated against player.Character on every sync. Same
	character + live track -> keep (no reload pop). New
	character -> old track stopped, fresh LoadAnimation on the
	new Animator. CharacterAdded re-sync covers a carry that
	survives replacement; Died/Clear/leave paths stop via the
	feed. The Animator and all other tracks are never touched.

	No timers, no polling, no per-player loops: one registry
	hook + two global Players connections (CharacterAdded
	re-sync, PlayerRemoving cleanup).
]]

local Players = game:GetService('Players')
local ServerStorage = game:GetService('ServerStorage')
local ServerScriptService = game:GetService('ServerScriptService')

local CarryRegistry = require(script.Parent.CarryRegistry)
local Debug = require(script.Parent.Parent.Parent.ReplicatedStorage.Utility.Debug)

local PlayerGrabService = {}

-- Blending configuration. Action4 is the highest non-Core
-- tier: it outranks the stock Animate script's Idle/Movement
-- locomotion AND any other gameplay Action tracks (emotes,
-- dances, tool holds), so the carry pose cannot be overridden
-- while held. Core is deliberately not used (reserved above
-- gameplay). Looped keeps the pose for the whole carry. See
-- the header for the authoring assumption.
local GRAB_PRIORITY = Enum.AnimationPriority.Action4
local FADE_SECONDS = 0.1

-- Live entries: [userId] = { character, animator, track, txId }.
-- txId identifies the carry generation (record + startedAt) for
-- diagnostics; it never gates stop/start by itself.
local entries: { [number]: any } = {}
-- Registry hook handle (re-subscribed on every Init so the
-- wiring survives any CarryRegistry.Init order); Players
-- connections below are connected exactly once.
local unsubscribeHook: (() -> ())? = nil
local playersWired = false

-- Warn-once per (userId, step); cleared on the next successful
-- Grab start so a later regression re-warns. Event-driven, so
-- no per-frame spam is possible by construction.
local warned: { [string]: boolean } = {}

local function warnOnce(userId: number, step: string, message: string)
	local key = tostring(userId) .. ':' .. step
	if warned[key] then
		return
	end
	warned[key] = true
	Debug.Warn('PlayerGrab', message)
end

local function clearWarns(userId: number)
	local prefix = tostring(userId) .. ':'
	for key in pairs(warned) do
		if string.sub(key, 1, #prefix) == prefix then
			warned[key] = nil
		end
	end
end

local function transactionIdFor(item: any): string
	local tx, started = '?', '?'
	if type(item) == 'table' then
		if type(item.record) == 'table' and type(item.record.uniqueId) == 'string' then
			tx = item.record.uniqueId
		end
		if item.startedAt ~= nil then
			started = tostring(item.startedAt)
		end
	end
	return tx .. '@' .. started
end

-- Resolve the authored asset. Cached after first success; every
-- miss warns (never silent, never hardcoded id, never cloned).
local cachedAsset: Animation? = nil
local function resolveAsset(): Animation?
	if cachedAsset ~= nil and cachedAsset.Parent ~= nil then
		return cachedAsset
	end
	cachedAsset = nil
	local assets = ServerStorage:FindFirstChild('Assets')
	local animations = assets and assets:FindFirstChild('Animations') or nil
	local playerFolder = animations and animations:FindFirstChild('Player') or nil
	local grab = playerFolder and playerFolder:FindFirstChild('Grab') or nil
	if grab == nil or not grab:IsA('Animation') then
		return nil
	end
	cachedAsset = grab
	return cachedAsset
end

local function stopEntry(userId: number)
	local entry = entries[userId]
	if not entry then
		return
	end
	entries[userId] = nil
	pcall(function()
		if entry.track ~= nil then
			entry.track:Stop(FADE_SECONDS)
		end
	end)
end

local function ensureGrab(player: Player, userId: number, item: any)
	local character = player.Character
	if typeof(character) ~= 'Instance' or (character :: Model).Parent == nil then
		warnOnce(userId, 'no-character', ('Carry started but Character is invalid for player=%s'):format(player.Name))
		return
	end
	local model = character :: Model
	local humanoid = model:FindFirstChildOfClass('Humanoid')
	if not humanoid then
		warnOnce(userId, 'no-humanoid', ('Missing Humanoid for player=%s'):format(player.Name))
		return
	end
	local animator = humanoid:FindFirstChildOfClass('Animator')
	if not animator then
		warnOnce(userId, 'no-animator', ('Missing Animator for player=%s'):format(player.Name))
		return
	end
	-- Same live Character with a live Grab track: keep it (no
	-- reload pop across re-syncs, and a newer transaction
	-- inherits the pose without a visual hitch).
	local entry = entries[userId]
	if entry ~= nil and entry.character == model and entry.track ~= nil then
		local alive = false
		pcall(function()
			alive = entry.track.IsPlaying
		end)
		if alive then
			entry.txId = transactionIdFor(item)
			return
		end
	end
	-- New Character (or dead track): drop the old handle — never
	-- reference a destroyed Character's track again.
	if entry ~= nil then
		stopEntry(userId)
	end
	local asset = resolveAsset()
	if asset == nil then
		warnOnce(
			userId,
			'no-asset',
			'Grab animation asset missing: ServerStorage.Assets.Animations.Player.Grab'
		)
		return
	end
	if type(asset.AnimationId) ~= 'string' or asset.AnimationId == '' then
		warnOnce(userId, 'bad-id', 'Grab animation has invalid AnimationId')
		return
	end
	local ok, track = pcall(function()
		return animator:LoadAnimation(asset)
	end)
	if not ok or track == nil then
		warnOnce(userId, 'load-failed', ('Failed to load Grab animation for player=%s'):format(player.Name))
		return
	end
	pcall(function()
		(track :: AnimationTrack).Priority = GRAB_PRIORITY
		;(track :: AnimationTrack).Looped = true
	end)
	local playOk = pcall(function()
		(track :: AnimationTrack):Play(FADE_SECONDS, 1, 1)
	end)
	if not playOk then
		warnOnce(userId, 'play-failed', ('Failed to play Grab animation for player=%s'):format(player.Name))
		return
	end
	entries[userId] = {
		character = model,
		animator = animator,
		track = track,
		txId = transactionIdFor(item),
	}
	clearWarns(userId)
	Debug.Log('PG', 'Grab started', { userId = tostring(userId), tx = transactionIdFor(item) })
end

-- Reconcile one player's Grab state with the authoritative
-- registry. Never throws; never yields.
local function syncGrab(userId: number)
	local ok, err = pcall(function()
		local item = CarryRegistry.Get(userId)
		if type(item) ~= 'table' then
			stopEntry(userId)
			return
		end
		local player = Players:GetPlayerByUserId(userId)
		if player == nil then
			-- No Player object (removed, or Studio specs):
			-- drop the handle; the Character (and its tracks)
			-- is gone with the player either way.
			stopEntry(userId)
			return
		end
		ensureGrab(player, userId, item)
	end)
	if not ok then
		warnOnce(userId, 'sync-failed', ('Grab sync failed: %s'):format(tostring(err)))
	end
end

function PlayerGrabService.Init()
	if unsubscribeHook then
		pcall(unsubscribeHook)
		unsubscribeHook = nil
	end
	unsubscribeHook = CarryRegistry.OnChanged(syncGrab)
	if playersWired then
		return
	end
	playersWired = true
	Players.PlayerAdded:Connect(function(player: Player)
		player.CharacterAdded:Connect(function()
			-- A carry that survives replacement plays on the NEW
			-- Character only (validated inside ensureGrab).
			-- Normally the Died hook already cleared the carry,
			-- making this a cheap no-op that also heals any
			-- ordering edge.
			syncGrab(player.UserId)
		end)
	end)
	Players.PlayerRemoving:Connect(function(player: Player)
		stopEntry(player.UserId)
		clearWarns(player.UserId)
	end)
	Debug.Log('PG', 'Init: subscribed to CarryRegistry')
end

-- Server-side query: true while WE hold a live Grab track for
-- the player. Presentation diagnostics only — authority stays
-- with CarryRegistry.
function PlayerGrabService.IsPlaying(playerOrUserId: any): boolean
	local userId: number? = nil
	if typeof(playerOrUserId) == 'number' then
		userId = playerOrUserId
	elseif typeof(playerOrUserId) == 'Instance' and (playerOrUserId :: Instance):IsA('Player') then
		userId = (playerOrUserId :: Player).UserId
	end
	if not userId then
		return false
	end
	local entry = entries[userId]
	if entry == nil or entry.track == nil then
		return false
	end
	local alive = false
	pcall(function()
		alive = entry.track.IsPlaying
	end)
	return alive
end

-- TEST-ONLY seams.
function PlayerGrabService._TestReset()
	for key in pairs(entries) do
		pcall(function()
			if entries[key] ~= nil and entries[key].track ~= nil then
				entries[key].track:Stop()
			end
		end)
		entries[key] = nil
	end
	for key in pairs(warned) do
		warned[key] = nil
	end
end

function PlayerGrabService._TestEntryCount(): number
	local n = 0
	for _ in pairs(entries) do
		n += 1
	end
	return n
end

return table.freeze(PlayerGrabService)
