--!strict
--!native
--[[
	Shop.DoorService
	================
	Paid door opening for locked bases (Unlock Doors Developer
	Product). The door IS the lock state: a purchase unlocks
	the base through BaseLockService.UnlockPurchased AND
	records a per-buyer access grant. The grant is independent
	of the owner's lock control — the owner can ALWAYS
	re-lock afterwards (buyers keep collision passthrough via
	their grant; everyone else is locked out again). Grants
	persist for the base's lifetime (no duration in the
	product config) and clear only on base release/reassign/
	wipe; a new assignment starts with a clean door slate.

	Prompt lifecycle (server-owned, event-driven — never
	polled, never Heartbeat):
	  * Base locks   -> 'OpenDoorPrompt' created on the base
	    Collector (ownerUserId = owner, doorPrompt marker).
	  * Base unlocks -> prompt destroyed (any cause: owner
	    button, timer expiry, release, purchase grant).
	Client visibility (owner never sees it) is UX via the
	PromptOwnerFilter door rule; the server revalidates
	everything on trigger.

	Purchase flow:
	  prompt.Triggered (server) -> RequestOpen validates
	  (base exists+owned+locked, requester live + not owner +
	  in range + throttled) -> pending[userId] = { baseId,
	  ownerId } -> Marketplace PromptProductPurchase.
	Receipt -> GrantPendingUnlock revalidates from CURRENT
	 authoritative state (never trusts the stored context
	 blindly) -> UnlockPurchased(baseId, buyerUserId) or
	 terminal no-op. Terminal
	 no-ops consume the receipt (Granted) with a loud log AND
	 a buyer toast (never silent); only an internal error
	 retries. Pending survives leave (TTL-bound) so a
	 leave/rejoin mid-dialog still fulfills on retry.

	Steal semantics are untouched: this module never gates
	stealing and never reads StealService.
]]

local MarketplaceService = game:GetService('MarketplaceService')
local ServerScriptService = game:GetService('ServerScriptService')
local ReplicatedStorage = game:GetService('ReplicatedStorage')

local BaseService = require(ServerScriptService.BaseService)
local BaseLockService = require(ServerScriptService.Base.BaseLockService)
local ShopConfig = require(ReplicatedStorage.Config.Economy.Shop)
local PromptConfig = require(ReplicatedStorage.Config.World.Prompts)
local Security = require(ReplicatedStorage.Config.Systems.Security)
local Validation = require(ReplicatedStorage.Utility.Validation)
local NotificationService = require(ServerScriptService.Base.NotificationService)
local Debug = require(ReplicatedStorage.Utility.Debug)

local DoorService = {}

local PROMPT_NAME = 'OpenDoorPrompt'
-- Per-player purchase throttle (prompt spam guard; the receipt
-- itself is idempotent, this only gates prompt dialogs).
local REQUEST_COOLDOWN_S = Security.Door.RequestCooldownSeconds
-- Distance slack over the prompt's MaxActivationDistance for
-- server revalidation (movement between trigger and check).
local RANGE_SLACK = Security.Door.RangeSlackStuds

-- userId -> { baseId: string, ownerId: number, at: number }.
-- Base identity only (never Instance refs — bases rebuild).
-- Pending SURVIVES leave: a buyer who disconnects mid-dialog
-- and rejoins still gets their purchase fulfilled when the
-- receipt retries (revalidated live at grant time). Stale
-- entries die by TTL (swept lazily below), never by leave.
local _pending: { [number]: { baseId: string, ownerId: number, at: number } } = {}
local _lastRequestAt: { [number]: number } = {}
local _started = false
-- Pending purchase-context lifetime, seconds. Covers leave /
-- rejoin races and Roblox receipt retries; older contexts are
-- dropped (the receipt then consumes loudly instead of
-- unlocking a long-gone situation).
local PENDING_TTL_S = 15 * 60

local function _sweepStalePending(now: number)
	for userId, ctx in pairs(_pending) do
		if type(ctx) ~= 'table' or type(ctx.at) ~= 'number' or now - ctx.at > PENDING_TTL_S then
			_pending[userId] = nil
		end
	end
end

-- --- Prompt lifecycle ----------------------------------------------

local function _promptParent(base: any): BasePart?
	local collector = base and base.collector or nil
	if typeof(collector) == 'Instance' and collector:IsA('BasePart') then
		return collector
	end
	return nil
end

local function _findPrompt(parent: Instance?): ProximityPrompt?
	if typeof(parent) ~= 'Instance' then
		return nil
	end
	local found: ProximityPrompt? = nil
	pcall(function()
		for _, child in ipairs((parent :: Instance):GetChildren()) do
			if child:IsA('ProximityPrompt') and child.Name == PROMPT_NAME then
				found = child
				break
			end
		end
	end)
	return found
end

-- Reconcile one base's prompt with its live lock state.
-- Prompt exists IFF base is owned AND locked. Never throws.
function DoorService.RefreshBase(baseId: string)
	pcall(function()
		if type(baseId) ~= 'string' or baseId == '' then
			return
		end
		local base: any = nil
		pcall(function()
			base = BaseService.GetBaseById(baseId)
		end)
		local parent = _promptParent(base)
		local existing = _findPrompt(parent)
		local ownerId = base and base.ownerUserId or nil
		local locked = BaseLockService.IsLocked(baseId)
		local want = type(ownerId) == 'number' and locked == true and parent ~= nil
		if type(ownerId) == 'number' and locked == true and parent == nil then
			Debug.Warn('DOOR', 'locked base has no collector; prompt unavailable', { baseId = baseId })
		end
		if want then
			if existing then
				-- Re-stamp the owner (ownership may have
				-- changed while staying locked... in practice
				-- release unlocks first; stamp anyway).
				pcall(function()
					(existing :: ProximityPrompt):SetAttribute('ownerUserId', ownerId)
				end)
				return
			end
			local prompt = Instance.new('ProximityPrompt')
			prompt.Name = PROMPT_NAME
			prompt.ActionText = PromptConfig.DoorOpen.ActionText
			prompt.ObjectText = PromptConfig.DoorOpen.ObjectText
			prompt.HoldDuration = PromptConfig.DoorOpen.HoldDuration
			prompt.MaxActivationDistance = PromptConfig.DoorOpen.MaxActivationDistance
			prompt.RequiresLineOfSight = PromptConfig.DoorOpen.RequiresLineOfSight
			prompt:SetAttribute('ownerUserId', ownerId)
			prompt:SetAttribute('doorPrompt', true)
			prompt:SetAttribute('baseId', baseId)
			prompt.Parent = parent
			pcall(function()
				prompt.Triggered:Connect(function(player: Player)
					DoorService.RequestOpen(player, prompt)
				end)
			end)
			Debug.Log('DOOR', 'prompt created', { baseId = baseId })
		else
			if existing then
				pcall(function()
					(existing :: ProximityPrompt):Destroy()
				end)
				Debug.Log('DOOR', 'prompt removed', { baseId = baseId })
			end
		end
	end)
end

-- --- Purchase request (prompt trigger) -------------------------------

-- Server-side validation for opening a purchase dialog.
-- Never trusts client state: base, ownership, lock, liveness,
-- and distance all re-resolve here. Returns true when the
-- product prompt was shown (pending context stored).
function DoorService.RequestOpen(player: Player, prompt: ProximityPrompt): boolean
	local ok = false
	pcall(function()
		if not Validation.LivePlayer(player) then
			return
		end
		if not Validation.CanPlayerInteract(player) then
			return
		end
		if typeof(prompt) ~= 'Instance' or not prompt:IsA('ProximityPrompt') then
			return
		end
		local baseId: any = nil
		pcall(function()
			baseId = prompt:GetAttribute('baseId')
		end)
		if type(baseId) ~= 'string' or baseId == '' then
			return
		end
		local base: any = nil
		pcall(function()
			base = BaseService.GetBaseById(baseId)
		end)
		if type(base) ~= 'table' or type(base.ownerUserId) ~= 'number' then
			return
		end
		if not BaseLockService.IsLocked(baseId) then
			Debug.Log('DOOR', 'rejected unlocked', { baseId = baseId, player = player.Name })
			return
		end
		if base.ownerUserId == player.UserId then
			Debug.Log('DOOR', 'rejected owner', { baseId = baseId, player = player.Name })
			return
		end
		-- Repeat interaction safety: a buyer who already holds
		-- a grant (owner re-locked after their purchase) is
		-- told so and never re-prompted / re-charged.
		if BaseLockService.HasPurchasedAccess(baseId, player.UserId) then
			Debug.Log('DOOR', 'already holds access; no new prompt', { baseId = baseId, player = player.Name })
			pcall(NotificationService.NotifySuccess, player, 'Shop_DoorOpened', {})
			ok = true
			return
		end
		-- Distance: prompt host part vs character root.
		local host = prompt.Parent
		local root: BasePart? = nil
		pcall(function()
			local character = player.Character
			root = character and character:FindFirstChild('HumanoidRootPart')
		end)
		if host == nil or not (host :: Instance):IsA('BasePart') or root == nil then
			return
		end
		local reach = PromptConfig.DoorOpen.MaxActivationDistance + RANGE_SLACK
		local dist = 0
		pcall(function()
			dist = ((host :: BasePart).Position - (root :: BasePart).Position).Magnitude
		end)
		if dist > reach then
			Debug.Log('DOOR', 'rejected out of range', {
				baseId = baseId,
				player = player.Name,
				dist = tostring(dist),
			})
			return
		end
		-- Throttle: one dialog per cooldown window.
		local now = os.clock()
		if (_lastRequestAt[player.UserId] or 0) + REQUEST_COOLDOWN_S > now then
			return
		end
		_lastRequestAt[player.UserId] = now
		_sweepStalePending(now)
		_pending[player.UserId] = { baseId = baseId, ownerId = base.ownerUserId, at = now }
		local productId = ShopConfig.DeveloperProducts.UnlockDoors.ProductId
		local prompted = false
		pcall(function()
			MarketplaceService:PromptProductPurchase(player, productId)
			prompted = true
		end)
		if not prompted then
			_pending[player.UserId] = nil
			return
		end
		Debug.Log('DOOR', 'purchase requested', { baseId = baseId, player = player.Name })
		ok = true
	end)
	return ok
end

-- --- Receipt grant -----------------------------------------------------

-- Fulfill a validated Unlock Doors purchase for the pending
-- base. Re-resolves CURRENT authoritative state (the pending
-- context is only a locator): grants when the base is still
-- owned by the same owner and the buyer is still a
-- non-owner. Terminal no-op paths (already open, ownership
-- changed, buyer-is-owner, unrecoverable context) consume the
-- receipt (true) with a loud log AND a buyer toast — a paid
-- purchase is never swallowed silently. False (retry) only on
-- internal error. Never notifies the base owner.
-- The grant is PURCHASED per-buyer (UnlockPurchased records
-- the buyer AND opens now): it persists for the base's
-- lifetime, the owner can still re-lock over it (the buyer
-- keeps passthrough; no one else does), and it clears on
-- base release/reassign. Repeat receipts re-insert the same
-- grant idempotently. Never trusts the stored context
-- blindly; never opens a stranger's base.
function DoorService.GrantPendingUnlock(player: Player?): boolean
	local settled = false
	pcall(function()
		local userId: number? = nil
		pcall(function()
			userId = player and (player :: Player).UserId or nil
		end)
		if type(userId) ~= 'number' then
			-- Buyer gone and no pending locator: nothing to do.
			-- (With a pending context we could still unlock,
			-- but without a userId there is no context key.)
			settled = true
			return
		end
		_sweepStalePending(os.clock())
		local pending = _pending[userId]
		_pending[userId] = nil
		if type(pending) ~= 'table' or type(pending.baseId) ~= 'string' then
			Debug.Warn('DOOR', 'no pending door context; purchase consumed', { userId = tostring(userId) })
			if player ~= nil then
				pcall(NotificationService.NotifyWarning, player, 'General_Generic', {})
			end
			settled = true
			return
		end
		local base: any = nil
		pcall(function()
			base = BaseService.GetBaseById(pending.baseId)
		end)
		if type(base) ~= 'table' or type(base.ownerUserId) ~= 'number' then
			Debug.Warn('DOOR', 'base gone; purchase consumed', {
				baseId = tostring(pending.baseId),
				userId = tostring(userId),
			})
			if player ~= nil then
				pcall(NotificationService.NotifyWarning, player, 'General_Generic', {})
			end
			settled = true
			return
		end
		if not BaseLockService.IsLocked(pending.baseId) then
			-- Raced open (timer expired or another buyer's grant
			-- landed mid-dialog): the door is already open, but
			-- the buyer still paid for ACCESS — record the
			-- per-buyer grant when the context is otherwise
			-- valid (same owner, buyer still a non-owner) so a
			-- later owner re-lock keeps their passthrough.
			-- Anything else consumes loudly as before.
			if base.ownerUserId == pending.ownerId and base.ownerUserId ~= userId then
				BaseLockService.UnlockPurchased(pending.baseId, userId)
				Debug.Log('DOOR', 'door already open; grant recorded', {
					baseId = tostring(pending.baseId),
					userId = tostring(userId),
				})
				if player ~= nil then
					pcall(NotificationService.NotifySuccess, player, 'Shop_DoorOpened', {})
				end
				settled = true
				return
			end
			Debug.Warn('DOOR', 'base already unlocked; purchase consumed', {
				baseId = tostring(pending.baseId),
				userId = tostring(userId),
			})
			if player ~= nil then
				pcall(NotificationService.NotifyWarning, player, 'General_Generic', {})
			end
			settled = true
			return
		end
		if base.ownerUserId ~= pending.ownerId then
			-- Ownership changed mid-purchase: never unlock a
			-- new owner's base on an old buyer's receipt.
			Debug.Warn('DOOR', 'ownership changed; purchase consumed without unlock', {
				baseId = tostring(pending.baseId),
				userId = tostring(userId),
			})
			if player ~= nil then
				pcall(NotificationService.NotifyWarning, player, 'General_Generic', {})
			end
			settled = true
			return
		end
		if player ~= nil and base.ownerUserId == userId then
			Debug.Warn('DOOR', 'buyer is now the owner; purchase consumed without unlock', {
				baseId = tostring(pending.baseId),
				userId = tostring(userId),
			})
			if player ~= nil then
				pcall(NotificationService.NotifyWarning, player, 'General_Generic', {})
			end
			settled = true
			return
		end
		-- Purchased per-buyer grant: opens NOW, records the
		-- buyer (passthrough survives later owner re-locks),
		-- idempotent on repeat receipts. Global: server
		-- geometry replicates to everyone.
		BaseLockService.UnlockPurchased(pending.baseId, userId)
		Debug.Log('DOOR', 'door opened (purchased)', { baseId = tostring(pending.baseId), userId = tostring(userId) })
		if player ~= nil then
			pcall(NotificationService.NotifySuccess, player, 'Shop_DoorOpened', {})
		end
		settled = true
	end)
	return settled
end

-- --- Lifecycle -----------------------------------------------------------

-- Named subscriber (module-level so SubscribeLockChanged can
-- dedupe it: repeated Init calls never stack subscriptions).
local function _onLockChanged(info: any)
	pcall(function()
		if type(info) == 'table' and type(info.baseId) == 'string' then
			DoorService.RefreshBase(info.baseId)
		end
	end)
end

function DoorService.Init()
	if _started then
		return
	end
	_started = true
	BaseLockService.SubscribeLockChanged(_onLockChanged)
	Debug.Log('DOOR', 'door service ready', {})
end

function DoorService.ForgetPlayer(userId: number)
	if type(userId) ~= 'number' then
		return
	end
	-- Throttle is session-scoped; the purchase context is NOT
	-- cleared (a buyer who leaves mid-dialog and rejoins still
	-- fulfills on receipt retry — revalidated live, TTL-bound).
	_lastRequestAt[userId] = nil
end

-- TEST-ONLY seams.
function DoorService._TestReset()
	table.clear(_pending)
	table.clear(_lastRequestAt)
	_started = false
end

function DoorService._TestPending(userId: number): any?
	return _pending[userId]
end

-- TEST-ONLY seam: plant a purchase context (the prompt path
-- is Studio-only: real dialogs + real characters).
function DoorService._TestSetPending(userId: number, ctx: any?)
	if type(userId) ~= 'number' then
		return
	end
	if type(ctx) ~= 'table' then
		_pending[userId] = nil
		return
	end
	_pending[userId] = ctx
end

return table.freeze(DoorService)
