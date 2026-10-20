--!strict
--!native
--[[
	ShopController
	==============
	Client glue for the Studio-authored Robux Shop
	(PlayerGui.Main.Shop, opened by PlayerGui.HUD.ShopButton).

	Startup binding is immediate: bounded waits on
	PlayerGui/Main/Shop only — never profile, base, animals,
	eggs, viewport population, or any server system. Shop
	starts closed; ShopButton toggles; TopBar.CloseButton
	closes. All bindings carry Connected guards so respawns
	and re-inits can never duplicate connections.

	Buy buttons: TextButtons named exactly 'Buy' under the
	Shop panel that carry a numeric `ProductId` attribute
	(matching ShopConfig) — or are named exactly after a
	ShopConfig product key — prompt the corresponding
	Marketplace purchase:
	  * Developer Products -> PromptProductPurchase (receipts
	    resolve server-side; no client follow-up needed).
	  * 2X Money gamepass -> PromptGamePassPurchase, then a
	    ShopAction 'SyncGamepass' ping on dialog close so the
	    server applies the entitlement without waiting for a
	    rejoin (already-owned dialogs are handled natively by
	    Roblox; the server re-checks authoritatively anyway).
	Buttons named 'Gift' are NEVER touched: no gifting system
	exists, so gifting stays safely unimplemented.

	No prices, names, or IDs live here: ShopConfig is the
	single registry (replicated module, client-readable).
]]

local Players = game:GetService('Players')
local MarketplaceService = game:GetService('MarketplaceService')

local Debug = require(game:GetService('ReplicatedStorage').Utility.Debug)
local ShopConfig = require(game:GetService('ReplicatedStorage').Config.Economy.Shop)
local Remotes = require(game:GetService('ReplicatedStorage').Utility.Remotes)
local HudTree = require(script.Parent.HudTree)
local MenuPresentation = require(script.Parent.MenuPresentation)

local ShopController = {}

local PLAYER_GUI_WAIT_S = 10
local MAIN_WAIT_S = 10
local SHOP_WAIT_S = 10
local HUD_WAIT_S = 10

local _started = false
local _shopFrame: GuiObject? = nil
-- Bound-button registry (button -> card key) for DebugDump +
-- duplicate protection across re-scans.
local _bound: { [Instance]: string } = {}
local _watchConnected = false
local _scanCount = 0
local _rescanPending = false
local _lastClick = 'none'
-- Funnel prompt-intent ping (analytics ONLY): tells the server
-- a real Roblox dialog was shown so it can log ShopItemPrompted
-- on the existing ShopAction remote. Best-effort; a missing
-- remote or failed ping never affects the purchase itself.
local function _pingPrompt(payload: { [string]: any })
	pcall(function()
		local folder = Remotes.WaitForReady()
		if folder == nil then
			return
		end
		local remote = (folder :: Instance):FindFirstChild(Remotes.Names.ShopAction)
		if remote ~= nil and (remote :: Instance):IsA('RemoteEvent') then
			((remote :: Instance) :: RemoteEvent):FireServer(payload)
		end
	end)
end
-- Unmapped-card paths already reported once (scan + re-scans
-- would otherwise repeat the same four lines forever).
local _warnedPaths: { [string]: boolean } = {}

local function _boundCount(): number
	local n = 0
	for _ in pairs(_bound) do
		n += 1
	end
	return n
end

local function warnShop(message: string)
	Debug.Warn('ShopController', message)
end

local function logShop(message: string)
	Debug.Log('ShopController', message)
end

-- Clickability census for one candidate button. A GuiButton
-- only fires Activated when it (and every GuiObject ancestor
-- up to the ScreenGui) is Visible, the button itself is
-- Active, and nothing modal eats the input. Any breakage is
-- warned loudly with the exact link; healthy buttons log one
-- line so a missing line means the button was never scanned.
local function _logClickable(descendant: Instance)
	pcall(function()
		local button = descendant :: GuiButton
		local active = (button.Active == true)
		local visible = (button.Visible == true)
		local selectable = true
		pcall(function()
			selectable = (button :: any).Selectable ~= false
		end)
		local chain = 'self'
		local node: Instance? = button.Parent
		local guard = 0
		while node ~= nil and guard < 16 do
			guard += 1
			if (node :: Instance):IsA('GuiObject') and (node :: GuiObject).Visible == false then
				chain = ('hidden-ancestor=%s'):format((node :: Instance):GetFullName())
				break
			end
			if (node :: Instance):IsA('ScreenGui') then
				if (node :: ScreenGui).Enabled == false then
					chain = ('disabled-screen=%s'):format((node :: Instance):GetFullName())
				end
				break
			end
			node = (node :: Instance).Parent
		end
		local size = (button :: GuiObject).AbsoluteSize
		if not active or not visible or not selectable or chain ~= 'self' then
			warnShop(
				('[Shop] NOT-CLICKABLE button=%s active=%s visible=%s selectable=%s chain=%s size=%s'):format(
					button:GetFullName(),
					tostring(active),
					tostring(visible),
					tostring(selectable),
					chain,
					tostring(size)
				)
			)
		else
			logShop(
				('[Shop] clickable button=%s zIndex=%s size=%s'):format(
					button:GetFullName(),
					tostring((button :: GuiObject).ZIndex),
					tostring(size)
				)
			)
		end
	end)
end

-- Resolve a clicked Buy button to a ShopConfig product entry:
-- numeric ProductId attribute first, ScrollingFrame-relative
-- card path (ShopConfig.CardMap) second, exact product-key
-- name third (e.g. a card button literally named 'MoneyPack1').
-- Gift buttons never resolve (caller skips them).
local function cardPathOf(button: Instance, area: Instance?): string?
	local parts: { string } = {}
	local node: Instance? = button.Parent
	local guard = 0
	while node ~= nil and node ~= area and guard < 16 do
		guard += 1
		table.insert(parts, 1, node.Name)
		node = node.Parent
	end
	if #parts == 0 then
		return nil
	end
	return table.concat(parts, '/')
end

local function resolveProduct(button: Instance, area: Instance?): any?
	local productId: any = nil
	pcall(function()
		productId = (button :: Instance):GetAttribute('ProductId')
	end)
	if type(productId) == 'number' then
		local entry: any = nil
		pcall(function()
			entry = ShopConfig.FindProduct(productId)
		end)
		if entry ~= nil then
			return entry
		end
		warnShop(('button %s has unknown ProductId=%s'):format(button:GetFullName(), tostring(productId)))
	end
	if area ~= nil then
		local path = cardPathOf(button, area)
		if path ~= nil then
			local key: any = nil
			pcall(function()
				key = ShopConfig.CardMap[path]
			end)
			if type(key) == 'string' then
				local entry: any = nil
				pcall(function()
					entry = ShopConfig.DeveloperProducts[key] or ShopConfig.Gamepasses[key]
				end)
				if entry ~= nil then
					return entry
				end
			end
		end
	end
	local key = button.Name
	local keyed: any = nil
	pcall(function()
		keyed = ShopConfig.DeveloperProducts[key] or ShopConfig.Gamepasses[key]
	end)
	return keyed
end

local function isGamepassEntry(entry: any): boolean
	return type(entry) == 'table' and type(entry.GamepassId) == 'number'
end

local function productIdOf(entry: any): number?
	if type(entry) ~= 'table' then
		return nil
	end
	if type(entry.ProductId) == 'number' then
		return entry.ProductId
	end
	return nil
end

-- Local warning toast (no server round-trip): used only for
-- the already-owned gamepass pre-check. Everything else
-- feedback-wise travels on the server Notify channel. Display
-- still goes through the ONE canonical entry point
-- (ToastController.Push -> HUD.Center.Notifications); only the
-- origin is local, never a gameplay verdict.
local function warnLocal(text: string)
	pcall(function()
		local ToastController = require(script.Parent.ToastController)
		ToastController.Push({ Category = 'Warning', Text = text })
	end)
end

local function onBuyClicked(button: Instance, cardKey: string, area: Instance?)
	local entry = resolveProduct(button, area)
	if entry == nil then
		local path = cardPathOf(button, area) or '?'
		warnShop(
			('[Shop] ERROR: no product configured card=%s path=%s button=%s'):format(
				cardKey,
				path,
				button:GetFullName()
			)
		)
		return
	end
	-- Unlock Doors is contextual-only (Open Door prompt
	-- establishes the server-side pending target). A generic
	-- Shop Buy must never charge for it without a target.
	if entry.Kind == 'UnlockDoors' then
		warnShop(('[Shop] UnlockDoors has no door target from card=%s; buy via the Open Door prompt'):format(cardKey))
		return
	end
	local player = Players.LocalPlayer
	if player == nil then
		warnShop(('[Shop] click ignored (no LocalPlayer) card=%s'):format(cardKey))
		return
	end
	if isGamepassEntry(entry) then
		local gamepassId = entry.GamepassId
		-- Ownership pre-check: already owned -> warning
		-- instead of a redundant purchase dialog. A failed
		-- check fails OPEN toward the dialog (the server
		-- re-resolves authoritatively on sync regardless).
		local owned: boolean? = nil
		local checkOk = false
		pcall(function()
			owned = MarketplaceService:UserOwnsGamePassAsync(player.UserId, gamepassId)
			checkOk = true
		end)
		logShop(
			(
				('[Shop] click card=%s gamepass=%s ownsCheckOk=%s owned=%s'):format(
					cardKey,
					tostring(gamepassId),
					tostring(checkOk),
					tostring(owned)
				)
			)
		)
		_lastClick = ('gamepass %s owns=%s'):format(tostring(gamepassId), tostring(owned))
		if owned == true then
			warnLocal('You already own this!')
			logShop(('[Shop] Buy clicked card=%s (already owned, dialog skipped)'):format(cardKey))
			return
		end
		logShop(('[Shop] Buy clicked card=%s'):format(cardKey))
		logShop(('[Shop] PromptGamePassPurchase gamePassId=%s'):format(tostring(gamepassId)))
		local promptOk, promptErr = pcall(function()
			MarketplaceService:PromptGamePassPurchase(player, gamepassId)
		end)
		logShop(('[Shop] PromptGamePassPurchase returned ok=%s err=%s'):format(tostring(promptOk), tostring(promptErr)))
		if promptOk then
			_pingPrompt({ Action = 'FunnelPrompt', GamepassId = gamepassId })
		end
		_lastClick = ('gamepass %s promptOk=%s'):format(tostring(gamepassId), tostring(promptOk))
		return
	end
	local productId = productIdOf(entry)
	if productId == nil then
		warnShop(('[Shop] ERROR: product %s has no ProductId; cannot prompt'):format(tostring(entry.Key)))
		return
	end
	logShop(('[Shop] Buy clicked card=%s'):format(cardKey))
	logShop(('[Shop] PromptProductPurchase productId=%s'):format(tostring(productId)))
	local promptOk, promptErr = pcall(function()
		MarketplaceService:PromptProductPurchase(player, productId)
	end)
	logShop(('[Shop] PromptProductPurchase returned ok=%s err=%s'):format(tostring(promptOk), tostring(promptErr)))
	if promptOk then
		_pingPrompt({ Action = 'FunnelPrompt', ProductId = productId })
	end
	_lastClick = ('product %s promptOk=%s'):format(tostring(productId), tostring(promptOk))
end

-- Wire one Buy button exactly once (Connected guard survives
-- re-init/respawn). Gift/CloseButton/TopBar controls are
-- skipped by the caller. The ScrollingFrame-relative `area`
-- is captured here (NOT re-derived at click time): click-time
-- resolution must walk up to the SAME root the bind used, or
-- CardMap paths gain a 'ScrollingFrame/' prefix and miss.
local function wireBuyButton(button: Instance, cardKey: string, area: Instance?)
	local connected = false
	pcall(function()
		connected = (button :: Instance):GetAttribute('ShopBuyWired') == true
	end)
	if connected then
		return
	end
	pcall(function()
		(button :: Instance):SetAttribute('ShopBuyWired', true)
	end)
	pcall(function()
		((button :: Instance) :: GuiButton).Activated:Connect(function()
			logShop(('[Shop] Activated fired button=%s'):format(button:GetFullName()))
			onBuyClicked(button, cardKey, area)
		end)
	end)
	_bound[button] = cardKey
	logShop(('[Shop] Buy bound card=%s button=%s'):format(cardKey, button:GetFullName()))
end

-- Bind every purchasable affordance under the product area
-- (ScrollingFrame when present, else the Shop root). A button
-- qualifies by ProductId attribute, ScrollingFrame-relative
-- card path (ShopConfig.CardMap), or exact product-key name;
-- cards whose button IS the card (button named as the key)
-- bind the same way. Unmapped buttons log an ERROR naming the
-- card path so Studio gaps surface instead of failing silently.
local function wireBuyButtons(root: Instance)
	_scanCount += 1
	pcall(function()
		local area = (root :: Instance):FindFirstChild('ScrollingFrame') or root
		local topBar = (root :: Instance):FindFirstChild('TopBar')
		local total = #(area :: Instance):GetDescendants()
		local candidates = 0
		for _, descendant in ipairs((area :: Instance):GetDescendants()) do
			if topBar ~= nil and (descendant :: Instance):IsDescendantOf(topBar) then
				continue
			end
			if not (descendant:IsA('TextButton') or descendant:IsA('ImageButton')) then
				continue
			end
			if descendant.Name == 'Gift' or descendant.Name == 'CloseButton' then
				continue
			end
			candidates += 1
			-- Clickability census: if Activated never fires
			-- for a bound button, THIS line names why (dead
			-- Active/Visible/Selectable, buried ZIndex, or a
			-- hidden ancestor). Runs at bind time so a dead
			-- button is diagnosed without needing a click.
			_logClickable(descendant)
			local entry = resolveProduct(descendant, area)
			if entry == nil then				-- Unmapped Buy button: surface the card path
				-- loudly instead of leaving a dead button —
				-- once per path (re-scans don't repeat it).
				if descendant.Name == 'Buy' then
					local path = cardPathOf(descendant, area) or '?'
					if not _warnedPaths[path] then
						_warnedPaths[path] = true
						warnShop(
							('[Shop] ERROR: no product configured path=%s button=%s'):format(
								path,
								descendant:GetFullName()
							)
						)
					end
				end
				continue
			end
			-- Unlock Doors is contextual-only (the Open Door
			-- prompt establishes the server-side pending
			-- target). A generic Shop card for it can never
			-- work, so disable it rather than charging for a
			-- targetless purchase.
			if type(entry) == 'table' and entry.Kind == 'UnlockDoors' then
				pcall(function()
					(descendant :: GuiButton).Active = false
				end)
				logShop(
					('[Shop] UnlockDoors card disabled (contextual-only) button=%s'):format(descendant:GetFullName())
				)
				continue
			end
			-- A resolved product is useless if Roblox never
			-- delivers the click: Activated requires Active.
			-- Authored Active=false (the live Shop ships it)
			-- would leave every bound button dead, so flip it
			-- here — behavior flag only, never visual. Unmapped
			-- buttons keep their authored state untouched.
			pcall(function()
				if (descendant :: GuiButton).Active ~= true then
					(descendant :: GuiButton).Active = true
					logShop(('[Shop] Active enabled button=%s'):format(descendant:GetFullName()))
				end
			end)
			wireBuyButton(descendant, tostring(entry.Key), area)
		end
		logShop(
			('[Shop] scan done area=%s descendants=%s candidates=%s boundTotal=%s'):format(
				area:GetFullName(),
				total,
				candidates,
				tostring(_boundCount())
			)
		)
	end)
end

-- Queued re-scan: cards/buttons that stream in after Init
-- (StreamingEnabled, dynamic UI) get bound late. Debounced;
-- the ShopBuyWired guard keeps it idempotent.
local function requestRescan()
	if _rescanPending or _shopFrame == nil then
		return
	end
	_rescanPending = true
	task.delay(0.5, function()
		_rescanPending = false
		if _shopFrame ~= nil then
			logShop('[Shop] re-scan triggered')
			wireBuyButtons(_shopFrame)
		end
	end)
end

-- Watch for late-arriving buttons (one connection, debounced
-- re-scan). Bound registry doubles as the duplicate guard.
local function watchLateButtons(root: Instance)
	if _watchConnected then
		return
	end
	_watchConnected = true
	pcall(function()
		(root :: Instance).DescendantAdded:Connect(function(descendant: Instance)
			if descendant:IsA('TextButton') or descendant:IsA('ImageButton') then
				logShop(('[Shop] late button arrived button=%s'):format(descendant:GetFullName()))
				requestRescan()
			end
		end)
	end)
end

-- Command-bar diagnostic: prints every bound button, the last
-- click trace, and frame state. Run in a playtest via:
-- require(game.Players.LocalPlayer.PlayerScripts.ShopController).DebugDump()
-- If a click produces no 'Activated fired' line, run
-- DebugButtons() below: it re-checks every bound button's
-- LIVE Active/Visible/parent state at call time.
function ShopController.DebugDump()
	logShop(('dump: scans=%s bound=%s lastClick=%s'):format(tostring(_scanCount), tostring(_boundCount()), _lastClick))
	for button, key in pairs(_bound) do
		local alive = 'dead'
		pcall(function()
			alive = if (button :: Instance).Parent ~= nil then 'alive' else 'dead'
		end)
		logShop(('[Shop] dump bound card=%s alive=%s button=%s'):format(tostring(key), alive, tostring(button)))
	end
	if _shopFrame ~= nil then
		logShop(('[Shop] dump frame visible=%s'):format(tostring((_shopFrame :: GuiObject).Visible)))
	else
		logShop('[Shop] dump frame=nil (Shop never resolved)')
	end
end

-- Live clickability re-check for every bound button (call
-- after a dead click): reports current Active / Visible /
-- ancestor chain per button. Run via:
-- require(game.Players.LocalPlayer.PlayerScripts.ShopController).DebugButtons()
function ShopController.DebugButtons()
	for button, key in pairs(_bound) do
		pcall(function()
			_logClickable(button :: Instance)
		end)
		logShop(('[Shop] debug card=%s button=%s'):format(tostring(key), tostring(button)))
	end
end

local function setShopVisible(visible: boolean)
	if _shopFrame == nil then
		return
	end
	-- Full menu presentation (UiOpen + overlay/blur + Pop on
	-- open; Pop out on close). Already-open/closed calls are
	-- safe no-ops inside.
	MenuPresentation.SetVisible(_shopFrame :: GuiObject, visible)
end

function ShopController.Init()
	if _started then
		return
	end
	_started = true
	-- Post-dialog gamepass refresh: whenever ANY gamepass
	-- purchase dialog closes, ask the server to re-resolve
	-- the 2X Money entitlement (join path already syncs; this
	-- covers in-session purchases without waiting for a
	-- rejoin). Server revalidates ownership; feedback travels
	-- on Notify.
	pcall(function()
		MarketplaceService.PromptGamePassPurchaseFinished:Connect(
			function(_player: Player, _gamepassId: number, _purchased: boolean)
				pcall(function()
					local folder = Remotes.WaitForReady()
					local remote = folder:WaitForChild(Remotes.Names.ShopAction, 10)
					if remote ~= nil and (remote :: Instance):IsA('RemoteEvent') then
						((remote :: Instance) :: RemoteEvent):FireServer({ Action = 'SyncGamepass' })
					end
				end)
			end
		)
	end)
	task.spawn(function()
		local ok, err = pcall(function()
			local player = Players.LocalPlayer
			if player == nil then
				warnShop('no LocalPlayer; shop disabled')
				return
			end
			local playerGui = player:WaitForChild('PlayerGui', PLAYER_GUI_WAIT_S)
			if playerGui == nil then
				warnShop('PlayerGui missing; shop disabled')
				return
			end
			local main = (playerGui :: PlayerGui):WaitForChild('Main', MAIN_WAIT_S)
			if main == nil then
				warnShop('PlayerGui.Main missing; shop disabled')
				return
			end
			local shop = (main :: Instance):WaitForChild('Shop', SHOP_WAIT_S)
			if shop == nil or not (shop :: Instance):IsA('GuiObject') then
				warnShop('PlayerGui.Main.Shop missing; shop disabled')
				return
			end
			_shopFrame = shop :: GuiObject
			-- Shop starts closed; the button owns visibility.
			setShopVisible(false)
			-- Open/close binding: HUD.ShopButton toggles,
			-- TopBar.CloseButton closes. Instant, no waits
			-- beyond the HUD itself.
			local hud: Instance? = nil
			pcall(function()
				hud = (playerGui :: PlayerGui):WaitForChild('HUD', HUD_WAIT_S)
			end)
			if hud ~= nil then
				-- Nested HUD.Left.ShopButton (legacy flat fallback
				-- inside the resolver); bound once via attribute.
				local shopButton: Instance? = nil
				pcall(function()
					shopButton = HudTree.ShopButton(playerGui)
				end)
				if shopButton ~= nil and (shopButton :: Instance):IsA('GuiButton') then
					local bound = false
					pcall(function()
						bound = (shopButton :: Instance):GetAttribute('ShopToggleWired') == true
					end)
					if not bound then
						pcall(function()
							(shopButton :: Instance):SetAttribute('ShopToggleWired', true)
						end)
						pcall(function()
							((shopButton :: Instance) :: GuiButton).Activated:Connect(function()
								if _shopFrame ~= nil then
									local opening = not (_shopFrame :: GuiObject).Visible
									setShopVisible(not (_shopFrame :: GuiObject).Visible)
									if opening then
										-- Cards may stream in after
										-- Init; re-scan on every
										-- open (idempotent).
										wireBuyButtons(_shopFrame)
									end
								end
							end)
						end)
						logShop('ShopButton bound')
						-- Normal gameplay owns the Left chain: make sure
						-- the button can actually appear.
						HudTree.EnsureChainVisible(shopButton)
					end
				else
					warnShop('HUD.ShopButton missing; shop opens via panel only')
				end
			end
			local topBar = (shop :: Instance):FindFirstChild('TopBar')
			local close = if topBar ~= nil then topBar:FindFirstChild('CloseButton') else nil
			if close ~= nil and (close :: Instance):IsA('GuiButton') then
				local bound = false
				pcall(function()
					bound = (close :: Instance):GetAttribute('ShopCloseWired') == true
				end)
				if not bound then
					pcall(function()
						(close :: Instance):SetAttribute('ShopCloseWired', true)
					end)
					pcall(function()
						((close :: Instance) :: GuiButton).Activated:Connect(function()
							setShopVisible(false)
						end)
					end)
					logShop('CloseButton bound')
				end
			else
				warnShop('Shop.TopBar.CloseButton missing; toggle only')
			end
			-- Buy affordances last (panel must exist first),
			-- plus a watcher for buttons that arrive later.
			wireBuyButtons(shop :: Instance)
			watchLateButtons(shop :: Instance)
			logShop('shop controller ready')
		end)
		if not ok then
			warnShop(('init failed: %s'):format(tostring(err)))
		end
	end)
end

return table.freeze(ShopController)
