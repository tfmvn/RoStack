--!strict
--!native
--[[
	Shop.ShopService
	================
	Thin monetization layer over existing gameplay services.
	Owns the ONE authoritative MarketplaceService.ProcessReceipt
	implementation; every Developer Product resolves through
	ShopConfig to a canonical server action:

	  Money      -> EconomyService.AddMoney (ShopMoneyPack)
	  Gear       -> GearShopService.GrantRobuxGear (Galaxy Bat)
	  ServerLuck -> ServerLuckService.ActivateBoost (temp boost)
	  SkipDaily  -> DailyRewardsService.ClaimAll
	  SkipPlay   -> PlaytimeRewardsService.ClaimAll
	  Doors      -> DoorService.GrantPendingUnlock (pending ctx)

	Receipt rules (Roblox semantics):
	  * Duplicate PurchaseId -> Granted immediately (idempotent;
	    the first pass already fulfilled it).
	  * Unknown ProductId -> NotProcessedYet + loud warn (config
	    error; retries until the registry is fixed).
	  * Buyer gone -> server-wide effects (luck) still apply;
	    player-bound grants return NotProcessedYet (Roblox
	    retries; rejoins fulfill).
	  * Player-bound grants that fail transiently ->
	    NotProcessedYet (all grant paths are idempotent, so a
	    retry continues instead of duplicating).

	Also owns gamepass entitlement sync (2X Money): Roblox
	gamepasses emit no receipts, so ownership is re-checked
	authoritatively on join (OnPlayerReady) and on explicit
	ShopAction 'SyncGamepass' after an in-session purchase.
	Modifier sources are session-scoped (ModifierService
	never persists); the gamepass entitlement itself is the
	persistent source, re-resolved every session.
]]

local MarketplaceService = game:GetService('MarketplaceService')
local Players = game:GetService('Players')
local ServerScriptService = game:GetService('ServerScriptService')
local ReplicatedStorage = game:GetService('ReplicatedStorage')

local ShopConfig = require(ReplicatedStorage.Config.Economy.Shop)
local Security = require(ReplicatedStorage.Config.Systems.Security)
local Debug = require(ReplicatedStorage.Utility.Debug)
local Validation = require(ReplicatedStorage.Utility.Validation)
local NotificationService = require(ServerScriptService.Base.NotificationService)
local Remotes = require(ReplicatedStorage.Utility.Remotes)
local EconomyService = require(ServerScriptService.EconomyService)
local GearShopService = require(ServerScriptService.GearShop.GearShopService)
local ServerLuckService = require(ServerScriptService.ServerLuckService)
local ModifierService = require(ServerScriptService.ModifierService)
local DailyRewardsService = require(ServerScriptService.Daily.DailyRewardsService)
local PlaytimeRewardsService = require(ServerScriptService.Playtime.PlaytimeRewardsService)
local DoorService = require(ServerScriptService.Shop.DoorService)
-- Funnel analytics (leaf module — never gameplay-critical; every
-- LogStep is pcall-guarded inside, call sites add one more).
local FunnelService = require(ServerScriptService.FunnelService)
-- Player monitoring (Discord embeds + registry; leaf module,
-- never gameplay-critical, never in the receipt decision).
local PlayerLogger = require(ServerScriptService.PlayerLogger.PlayerLogger)

local ShopService = {}

-- Gamepass source identity for the 2X Money modifier.
local GAMEPASS_2X_SOURCE = 'Gamepass_2XMoney'

-- Seen PurchaseIds for idempotent receipts. Bounded: cleared
-- with a warn past the cap (Roblox retries promptly, so an
-- ancient duplicate re-granting is the accepted residual risk
-- over unbounded memory growth).
local _seenReceipts: { [string]: number } = {}
local _SEEN_CAP = Security.Receipts.SeenCap

-- Per-player ShopAction throttle (dialog-close bursts must not
-- stack expensive ownership checks). Declared up here so
-- ForgetPlayer (below) captures the local, not a global.
local _lastShopActionAt: { [number]: number } = {}
local SHOP_ACTION_COOLDOWN_S = Security.Receipts.ActionCooldownSeconds

local _started = false

-- --- Helpers -------------------------------------------------------

local function _rememberReceipt(purchaseId: string)
	_seenReceipts[purchaseId] = os.clock()
	local count = 0
	for _ in pairs(_seenReceipts) do
		count += 1
	end
	if count > _SEEN_CAP then
		table.clear(_seenReceipts)
		_seenReceipts[purchaseId] = os.clock()
		Debug.Warn('SHOP', 'receipt dedupe table overflowed; cleared', {})
	end
end

local function _buyerName(player: Player?): string
	if player ~= nil then
		local ok, name = pcall(function()
			return (player :: Player).Name
		end)
		if ok and type(name) == 'string' then
			return name
		end
	end
	return '?'
end

local function _celebrate(player: Player, textId: string, data: any)
	pcall(NotificationService.NotifySuccess, player, textId, data)
end

-- --- Gamepass sync (2X Money) ---------------------------------------

-- Authoritative entitlement check. Applies the session-scoped
-- MoneyMultiplier source when owned, removes it when not
-- (revoked/refunded edge). Quiet: callers decide feedback.
-- Returns true when the resolved state is owned.
function ShopService.SyncGamepassAsync(player: Player): boolean
	if not Validation.LivePlayer(player) then
		return false
	end
	local userId = player.UserId
	local owned = false
	pcall(function()
		owned = MarketplaceService:UserOwnsGamePassAsync(userId, ShopConfig.Gamepasses.Money2x.GamepassId)
	end)
	if owned then
		pcall(
			ModifierService.AddModifier,
			userId,
			GAMEPASS_2X_SOURCE,
			ModifierService.ModifierType.MoneyMultiplier,
			2,
			ModifierService.Operation.Multiply
		)
	else
		pcall(ModifierService.RemoveModifier, userId, GAMEPASS_2X_SOURCE)
	end
	-- Live base label: the owner's MoneyMultPart shows the new
	-- multiplier immediately. Lazy require: the label painter
	-- lives in RebirthService (no load-time coupling here).
	pcall(function()
		local okReb, rebSvc = pcall(require, script.Parent.Parent.Rebirth.RebirthService)
		if okReb and rebSvc and rebSvc.RefreshBaseMultiplier then
			rebSvc.RefreshBaseMultiplier(userId)
		end
	end)
	-- Funnel: entitlement synced (gamepasses emit no receipts,
	-- so this sync IS the authoritative success point).
	if owned then
		pcall(function()
			FunnelService:LogStep(player, 'Gamepass', 'GamepassSynced', {
				gamepass_id = ShopConfig.Gamepasses.Money2x.GamepassId,
			})
		end)
	end
	return owned
end

-- Join hook (bootstrap PlayerAdded, alongside
-- GearShopService.OnPlayerReady): silent entitlement sync.
function ShopService.OnPlayerReady(player: Player)
	pcall(ShopService.SyncGamepassAsync, player)
end

function ShopService.ForgetPlayer(userId: number)
	if type(userId) == 'number' then
		_lastShopActionAt[userId] = nil
	end
end

-- --- Product fulfillment --------------------------------------------

local function _grantMoney(player: Player, entry: any): string
	local amount = entry.Amount
	if type(amount) ~= 'string' or amount == '' then
		return 'retry'
	end
	local ok = false
	pcall(function()
		local res = EconomyService.AddMoney(player.UserId, amount, 'ShopMoneyPack')
		ok = type(res) == 'table' and res.Success == true
	end)
	if not ok then
		return 'retry'
	end
	-- NOTE: Amount is the RAW BigNumber decimal string.
	-- NotificationService owns ALL {Amount} formatting
	-- (_cleanAmount); a preformatted '$10K' value would fail
	-- sanitize there and render as '$0'.
	_celebrate(player, 'Shop_MoneyPack', { Amount = amount })
	return 'granted'
end

local function _grantGear(player: Player, entry: any, purchaseId: string?): string
	if type(entry.GearId) ~= 'string' or entry.GearId == '' then
		return 'retry'
	end
	local ok = false
	pcall(function()
		ok = GearShopService.GrantRobuxGear(player, entry.GearId) == true
	end)
	if not ok then
		-- Missing Tool asset (or transient): retry later, never
		-- consume. Loud warn so the asset gap gets fixed.
		Debug.Warn('SHOP', 'gear grant failed; receipt will retry', {
			gearId = tostring(entry.GearId),
			player = _buyerName(player),
		})
		return 'retry'
	end
	-- The Shop grants the GEAR (same item, same ownership —
	-- never a parallel Shop-only copy). Equip it once through
	-- the existing Gear equip path so a Robux purchase feels
	-- exactly like any other acquisition. Best-effort: the
	-- grant above already committed, so an equip miss (no
	-- character yet) defers to CharacterAdded, never retries.
	local equipOk, equipped = pcall(GearShopService.EquipGear, player, entry.GearId)
	_celebrate(player, 'Shop_GearGranted', { GearName = tostring(entry.Name or entry.GearId) })
	-- Funnel: Galaxy Bat equipped ONLY when the existing Gear
	-- path actually equipped it (never claimed on a miss).
	if equipOk and equipped == true and entry.GearId == 'GalaxyBat' then
		pcall(function()
			FunnelService:LogStep(player, 'GalaxyBat', 'GalaxyBatEquipped', {
				product_id = entry.ProductId,
				_key = if type(purchaseId) == 'string' then purchaseId else entry.Key,
			})
		end)
	end
	return 'granted'
end

local function _grantLuck(player: Player?, entry: any): string
	local mult = tonumber(entry.Multiplier)
	local durations = ShopConfig.ServerLuckDurations
	local duration = if type(durations) == 'table' then durations[mult] else nil
	if type(mult) ~= 'number' or type(duration) ~= 'number' then
		Debug.Warn('SHOP', 'luck product misconfigured; receipt will retry', {
			key = tostring(entry.Key),
		})
		return 'retry'
	end
	local token: number? = nil
	pcall(function()
		token = ServerLuckService.ActivateBoost(mult, duration, 'ShopPurchase')
	end)
	if token == nil then
		return 'retry'
	end
	-- Server-wide announcement (purchaser included): everyone
	-- shares the effect, everyone hears about it.
	local buyerName = _buyerName(player)
	pcall(function()
		for _, other in ipairs(Players:GetPlayers()) do
			NotificationService.NotifySuccess(other, 'Shop_LuckActivated', {
				PlayerName = buyerName,
				Multiplier = tostring(mult),
			})
		end
	end)
	if player ~= nil then
		pcall(NotificationService.NotifySuccess, player, 'Shop_LuckPurchased', {
			Multiplier = tostring(mult),
		})
	end
	return 'granted'
end

local function _grantSkipDaily(player: Player): string
	local ok = false
	local result: any = nil
	pcall(function()
		-- Receipt IS the entitlement: grant access first, then
		-- run the identical gated ClaimAll path.
		DailyRewardsService.GrantSkipAccess(player)
		result = DailyRewardsService.ClaimAll(player)
		ok = type(result) == 'table' and result.Success == true
	end)
	if not ok then
		return 'retry'
	end
	_celebrate(player, 'Shop_SkipDaily', {})
	return 'granted'
end

local function _grantSkipPlaytime(player: Player): string
	local ok = false
	local result: any = nil
	pcall(function()
		-- Receipt IS the entitlement: grant access first, then
		-- run the identical gated ClaimAll path.
		PlaytimeRewardsService.GrantSkipAccess(player)
		result = PlaytimeRewardsService.ClaimAll(player)
		ok = type(result) == 'table' and result.Success == true
	end)
	if not ok then
		return 'retry'
	end
	_celebrate(player, 'Shop_SkipPlaytime', {})
	return 'granted'
end

local function _grantUnlockDoors(player: Player?): string
	-- Buyer gone (leave mid-dialog): RETRY, not consume — the
	-- pending context survives leave (TTL-bound), so a rejoin
	-- fulfills instead of eating the purchase. Matches the
	-- service's receipt rule for player-bound grants.
	if player == nil then
		return 'retry'
	end
	local ok = false
	pcall(function()
		ok = DoorService.GrantPendingUnlock(player) == true
	end)
	-- Door grant resolves terminally in all validated paths
	-- (unlock, already-open no-op, stale-context no-op): the
	-- purchase is consumed either way. Only an internal error
	-- retries.
	return if ok then 'granted' else 'retry'
end

-- --- Receipt entry point ---------------------------------------------

local function _handleReceipt(info: any): Enum.ProductPurchaseDecision
	local purchaseId = type(info) == 'table' and info.PurchaseId or nil
	local playerId = type(info) == 'table' and info.PlayerId or nil
	local productId = type(info) == 'table' and info.ProductId or nil
	if type(purchaseId) ~= 'string' or type(playerId) ~= 'number' or type(productId) ~= 'number' then
		Debug.Warn('SHOP', 'malformed receipt info; granting to avoid retry loop', {})
		return Enum.ProductPurchaseDecision.PurchaseGranted
	end
	if _seenReceipts[purchaseId] ~= nil then
		return Enum.ProductPurchaseDecision.PurchaseGranted
	end
	local entry = ShopConfig.FindProduct(productId)
	if entry == nil then
		-- Unknown product: not ours to consume. Retry loudly
		-- so a registry gap gets fixed instead of silently
		-- eating a real purchase.
		Debug.Warn('SHOP', 'unknown ProductId; receipt will retry', { productId = tostring(productId) })
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	local player: Player? = nil
	pcall(function()
		player = Players:GetPlayerByUserId(playerId)
	end)
	Debug.Log('SHOP', 'purchase receipt', {
		product = tostring(entry.Key),
		productId = tostring(productId),
		player = _buyerName(player),
		purchaseId = tostring(purchaseId),
	})
	local outcome = 'retry'
	pcall(function()
		if entry.Kind == ShopConfig.ProductKind.Money then
			if player == nil then
				return
			end
			outcome = _grantMoney(player :: Player, entry)
		elseif entry.Kind == ShopConfig.ProductKind.Gear then
			if player == nil then
				return
			end
			outcome = _grantGear(player :: Player, entry, purchaseId)
		elseif entry.Kind == ShopConfig.ProductKind.ServerLuck then
			outcome = _grantLuck(player, entry)
		elseif entry.Kind == ShopConfig.ProductKind.SkipDaily then
			if player == nil then
				return
			end
			outcome = _grantSkipDaily(player :: Player)
		elseif entry.Kind == ShopConfig.ProductKind.SkipPlaytime then
			if player == nil then
				return
			end
			outcome = _grantSkipPlaytime(player :: Player)
		elseif entry.Kind == ShopConfig.ProductKind.UnlockDoors then
			outcome = _grantUnlockDoors(player)
		else
			Debug.Warn('SHOP', 'product kind has no handler; receipt will retry', {
				key = tostring(entry.Key),
				kind = tostring(entry.Kind),
			})
		end
	end)
	if outcome == 'granted' then
		_rememberReceipt(purchaseId)
		Debug.Log('SHOP', 'purchase granted', {
			product = tostring(entry.Key),
			player = _buyerName(player),
			purchaseId = tostring(purchaseId),
		})
		-- Funnel: receipt CONFIRMED + item GRANTED (both
		-- server-authoritative; a shown prompt is NOT success —
		-- only this branch is). Scoped per PurchaseId so
		-- retries/replays never double-count. Galaxy Bat adds
		-- its own funnel steps on the same receipt.
		pcall(function()
			local isGalaxy = entry.Kind == ShopConfig.ProductKind.Gear and entry.GearId == 'GalaxyBat'
			local buyer: Player? = player
			if buyer ~= nil then
				local meta = {
					product_id = productId,
					product_key = entry.Key,
					kind = entry.Kind,
					_key = purchaseId,
				}
				FunnelService:LogStep(buyer, 'Monetization', 'PurchaseConfirmed', meta)
				FunnelService:LogStep(buyer, 'Monetization', 'ItemGranted', meta)
				-- Player monitoring: granted branch runs once per
				-- PurchaseId, so retries never double-log.
				pcall(PlayerLogger.LogMilestone, buyer, 'PurchaseGranted', {
					product_key = entry.Key,
					kind = entry.Kind,
				})
				if isGalaxy then
					FunnelService:LogStep(buyer, 'GalaxyBat', 'GalaxyBatReceiptConfirmed', {
						product_id = productId,
						_key = purchaseId,
					})
					FunnelService:LogStep(buyer, 'GalaxyBat', 'GalaxyBatGranted', {
						product_id = productId,
						_key = purchaseId,
					})
				end
			elseif isGalaxy then
				-- Buyer gone mid-receipt (server-wide luck still
				-- applies; gear cannot): nothing player-scoped
				-- to attribute — skip honestly, never invent.
				Debug.Log('SHOP', 'galaxy grant unattributed (buyer gone)', {
					purchaseId = tostring(purchaseId),
				})
			end
		end)
		return Enum.ProductPurchaseDecision.PurchaseGranted
	end
	return Enum.ProductPurchaseDecision.NotProcessedYet
end

-- --- Lifecycle ---------------------------------------------------------

-- Purchase-prompt intent (analytics ONLY, never an
-- entitlement): the client fires this on the existing
-- ShopAction remote right after showing a real Roblox
-- purchase dialog. The server re-resolves the product from
-- ShopConfig (client numbers are never trusted for grants —
-- this only labels the funnel step). Throttled: modal
-- dialogs cannot spam, but exploit traffic is dropped.
local _lastPromptAt: { [number]: number } = {}
local PROMPT_COOLDOWN_S = 2

local function _logPromptIntent(player: Player, payload: any)
	if type(payload) ~= 'table' then
		return
	end
	local now = os.clock()
	if (_lastPromptAt[player.UserId] or 0) + PROMPT_COOLDOWN_S > now then
		return
	end
	_lastPromptAt[player.UserId] = now
	local productId = payload.ProductId
	local gamepassId = payload.GamepassId
	if type(productId) == 'number' then
		local entry = ShopConfig.FindProduct(productId)
		if entry == nil then
			return
		end
		local meta = { product_id = productId, product_key = entry.Key, kind = entry.Kind }
		FunnelService:LogStep(player, 'Monetization', 'ShopItemPrompted', meta)
		if entry.Kind == ShopConfig.ProductKind.Gear and entry.GearId == 'GalaxyBat' then
			FunnelService:LogStep(player, 'GalaxyBat', 'GalaxyBatPrompted', {
				product_id = productId,
			})
		end
	elseif type(gamepassId) == 'number' and gamepassId == ShopConfig.Gamepasses.Money2x.GamepassId then
		FunnelService:LogStep(player, 'Gamepass', 'GamepassPrompted', { gamepass_id = gamepassId })
	end
end

-- ShopAction ingress: post-purchase gamepass sync + funnel
-- prompt-intent pings (analytics only). Anything else is
-- ignored; entitlements re-resolve server-side regardless.
local function handleAction(player: Player, payload: any)
	local ok, err = pcall(function()
		if not Validation.LivePlayer(player) then
			return
		end
		if type(payload) ~= 'table' then
			return
		end
		if payload.Action == 'FunnelPrompt' then
			_logPromptIntent(player, payload)
			return
		end
		if payload.Action ~= 'SyncGamepass' then
			return
		end
		local now = os.clock()
		if (_lastShopActionAt[player.UserId] or 0) + SHOP_ACTION_COOLDOWN_S > now then
			return
		end
		_lastShopActionAt[player.UserId] = now
		local wasOwned = false
		pcall(function()
			for _, source in ipairs(ModifierService.GetModifiers(player.UserId)) do
				if type(source) == 'table' and source.SourceId == GAMEPASS_2X_SOURCE then
					wasOwned = true
					break
				end
			end
		end)
		local owned = ShopService.SyncGamepassAsync(player)
		if owned and not wasOwned then
			pcall(NotificationService.NotifySuccess, player, 'Shop_GamepassActive', {})
		elseif owned then
			pcall(NotificationService.NotifyWarning, player, 'Shop_AlreadyOwned', {})
		end
		pcall(Remotes.FireClient, player, Remotes.Names.ShopResult, {
			Action = 'SyncGamepass',
			Success = true,
			Owned = owned,
		})
		Debug.Log('SHOP', 'gamepass synced', { player = _buyerName(player), owned = tostring(owned) })
	end)
	if not ok then
		Debug.Warn('SHOP', 'ShopAction handler errored', { error = tostring(err) })
	end
end

-- Installs the single authoritative ProcessReceipt. Warns (but
-- proceeds) if something already claimed it — there must be
-- exactly one router; a second assignment would silently eat
-- receipts.
function ShopService.Init()
	if _started then
		return
	end
	_started = true
	pcall(function()
		MarketplaceService.ProcessReceipt = _handleReceipt
	end)
	-- ShopAction remote (gamepass sync after in-session
	-- purchase dialogs). Same WaitForChild discipline as the
	-- reward services: missing remote degrades loudly, never
	-- blocks boot.
	pcall(function()
		local folder = Remotes.GetFolder()
		local remote = folder:WaitForChild(Remotes.Names.ShopAction, 10)
		assert(remote and remote:IsA('RemoteEvent'), 'ShopAction remote missing')
		local actionRemote = remote :: RemoteEvent
		actionRemote.OnServerEvent:Connect(handleAction)
	end)
	-- Luck expiry announcement: the boost ended server-wide,
	-- so the whole server hears it (one toast each).
	ServerLuckService.OnBoostExpired(function(_info: any)
		pcall(function()
			for _, other in ipairs(Players:GetPlayers()) do
				NotificationService.NotifySuccess(other, 'Shop_LuckExpired', {})
			end
		end)
	end)
	Debug.Log('SHOP', 'receipt router installed', {})
end

-- TEST-ONLY seams.
function ShopService._TestReset()
	table.clear(_seenReceipts)
	table.clear(_lastShopActionAt)
	table.clear(_lastPromptAt)
	_started = false
end

function ShopService._TestHandleReceipt(info: any): Enum.ProductPurchaseDecision
	return _handleReceipt(info)
end

return table.freeze(ShopService)
