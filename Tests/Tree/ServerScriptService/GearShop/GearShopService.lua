--!strict
--!native
--[[
	GearShopService
	================
	Server-authoritative Gear Shop: session purchases, AutoBuy
	preferences, Tool grants, and shop-prompt wiring.

	Authority model:
	  GearConfig (ReplicatedStorage display data + rules)
	        |
	        +-- server re-resolves EVERYTHING from GearId
	        v
	  Purchase: validate -> TrySpendMoney (atomic) -> grant
	    -> equip THAT EXACT bat (server moves it to Character)
	  DefaultBat: granted + equipped on every join (free,
	    permanent fallback; auto-buy may replace it after)
	  Respawn: re-grant owned tools + re-equip session choice
	    (join choice preserved; only a fresh join resets)
	  AutoBuy:  persisted preference -> silent attempt on join
	  Session:  ownedBy[userId] (runtime only, never persisted)
	    + equippedBy[userId] (one bat, never persisted)

	Boundaries respected:
	  * ServerStorage (Tools, GearTemplate) is server-only; the
	    client NEVER reads it. Tool previews are published once
	    at boot as script-stripped clones under
	    ReplicatedStorage.GearShopPreviews for ViewportFrames.
	  * Rebirth unlocks ride the live RebirthService value via
	    GetPlayerRebirth (documented seam): RequiredRebirth > 0
	    stays locked until the player completes that Rebirth.
	  * Money moves only through EconomyService (reason
	    GearPurchase); prices are BigNumber strings.
	  * No timers, no polling: prompt Triggered, remote
	    actions, and PlayerAdded drive everything.

	Studio requirements (all fail-soft with [GearShop] warns):
	  Workspace.Map.Shop.PromptPart (+ ProximityPrompt),
	  ServerStorage.Assets.Ui.GearShop.GearTemplate,
	  ServerStorage.Assets.Ui.GearShop.Tools.<ToolName>,
	  StarterGui GearShop GUI (client-resolved).
]]

local ReplicatedStorage = game:GetService('ReplicatedStorage')
local ServerStorage = game:GetService('ServerStorage')
local ServerScriptService = game:GetService('ServerScriptService')
local Workspace = game:GetService('Workspace')

local GearConfig = require(ReplicatedStorage.Config.Economy.Gear)
local PromptConfig = require(ReplicatedStorage.Config.World.Prompts)
local Remotes = require(ReplicatedStorage.Utility.Remotes)
local Validation = require(ReplicatedStorage.Utility.Validation)
local BigNumber = require(ReplicatedStorage.Utility.BigNumber)
local Debug = require(ReplicatedStorage.Utility.Debug)
local NotificationService = require(ServerScriptService.Base.NotificationService)
-- Funnel analytics (leaf module — never gameplay-critical).
local FunnelService = require(ServerScriptService.FunnelService)

local GearShopService = {}

local PREVIEW_FOLDER_NAME = 'GearShopPreviews'

local playerServiceRef: any = nil
local economyServiceRef: any = nil

-- Session ownership: [userId] -> { [gearId] = true }. Runtime
-- only — leaving the server discards it (never persisted).
local ownedBy: { [number]: { [string]: boolean } } = {}
-- Session equipped bat: [userId] -> gearId. Exactly one bat is
-- "equipped" (parented to the Character); ownership is the
-- multi-set above. Never persisted by design: every server
-- join starts on DefaultBat, then auto-buy may replace it.
local equippedBy: { [number]: string } = {}
-- Join-once guard: OnPlayerReady (default grant + auto-buy)
-- runs exactly once per server session per player.
local readyBy: { [number]: boolean } = {}
-- Per-player purchase mutex (spam-click guard).
local busyBy: { [number]: boolean } = {}
local started = false

-- The permanent starting bat. Every player owns and equips
-- this on join: no cash, no unlock, no gamepass, no rebirth.
function GearShopService.DefaultGearId(): string
	return 'DefaultBat'
end

function GearShopService.GetEquippedGear(userId: number): string?
	if type(userId) ~= 'number' then
		return nil
	end
	return equippedBy[userId]
end

function GearShopService.SetPlayerService(svc: any)
	playerServiceRef = svc
end

function GearShopService.SetEconomyService(svc: any)
	economyServiceRef = svc
end

-- --- Asset resolution (server-only) ----------------------------------

local function gearToolsFolder(): Folder?
	local assets = ServerStorage:FindFirstChild('Assets')
	local ui = assets and assets:FindFirstChild('Ui') or nil
	local shop = ui and ui:FindFirstChild('GearShop') or nil
	local tools = shop and shop:FindFirstChild('Tools') or nil
	if tools and tools:IsA('Folder') then
		return tools
	end
	return nil
end

local function toolsPathFor(toolName: string): string
	return 'ServerStorage.Assets.Ui.GearShop.Tools/' .. tostring(toolName)
end

-- Unified Tool resolution with explicit status (single source
-- for validation, purchase, and previews — no drift):
-- { found = Tool? , class = string? }. `class` is set when an
-- Instance exists under the exact ToolName but is not a Tool.
local function resolveToolStatus(toolName: string): { found: Tool?, class: string? }
	if type(toolName) ~= 'string' or toolName == '' then
		return { found = nil, class = nil }
	end
	local tools = gearToolsFolder()
	local node = tools and tools:FindFirstChild(toolName) or nil
	if node == nil then
		return { found = nil, class = nil }
	end
	if node:IsA('Tool') then
		return { found = node, class = nil }
	end
	return { found = nil, class = node.ClassName }
end

function GearShopService.ResolveTool(toolName: string): Tool?
	return resolveToolStatus(toolName).found
end

function GearShopService.ToolStatus(toolName: string): { found: Tool?, class: string? }
	return resolveToolStatus(toolName)
end

-- Rebirth count comes from RebirthService (single seam — this
-- module never stores it). pcall-guarded so shop snapshots survive
-- a missing/unwired RebirthService (fail-closed to 0 = locked).
-- Rebirth unlocks ARE gear unlocks: completing a Rebirth raises
-- GetRebirth, which flips GearConfig.IsLocked for every gear whose
-- RequiredRebirth is met — no second ownership or unlock store.
function GearShopService.GetPlayerRebirth(userId: number): number
	local rebirth = 0
	pcall(function()
		local RebirthService = require(script.Parent.Parent.Rebirth.RebirthService)
		rebirth = RebirthService.GetRebirth(userId)
	end)
	if type(rebirth) ~= 'number' or rebirth ~= math.floor(rebirth) or rebirth < 0 then
		return 0
	end
	return rebirth
end

local function autoBuyOf(data: any): { [string]: boolean }
	if type(data) == 'table' and type(data.GearAutoBuy) == 'table' then
		return data.GearAutoBuy
	end
	return {}
end

local function isOwned(userId: number, gearId: string): boolean
	return ownedBy[userId] ~= nil and ownedBy[userId][gearId] == true
end

-- CURRENT SERVER TOOL PRESENCE (the ONLY thing the shop UI
-- may call "Owned"): does a live Tool with the exact
-- source Tool Name currently sit in Backpack OR Character?
-- Character is checked because an equipped Tool reparents
-- there. Session `ownedBy` and persistent `GearAutoBuy`
-- are separate concepts and must never drive the UI alone.
local function hasLiveTool(player: Player, toolName: string): boolean
	if typeof(player) ~= 'Instance' or not player:IsA('Player') then
		return false
	end
	if type(toolName) ~= 'string' or toolName == '' then
		return false
	end
	local ok, present = pcall(function()
		local backpack = player:FindFirstChildOfClass('Backpack')
		local character = player.Character
		local function holds(container: Instance?): boolean
			if container == nil then
				return false
			end
			for _, child in ipairs(container:GetChildren()) do
				if child:IsA('Tool') and child.Name == toolName then
					return true
				end
			end
			return false
		end
		return holds(backpack) or holds(character)
	end)
	if not ok then
		return false
	end
	return present == true
end

function GearShopService.HasLiveTool(player: Player, toolName: string): boolean
	return hasLiveTool(player, toolName)
end

-- --- Post-grant Tool lifecycle trace (temporary diagnostics) ----
-- The grant path already proves clone + parent + verified. This
-- section answers what happens AFTER: validity of the authored
-- Tool, then event-driven ancestry tracking. Strictly
-- event-driven (Equipped / Activated / Unequipped /
-- AncestryChanged / Destroying on the clone, ChildAdded /
-- ChildRemoved on Backpack AND Character, CharacterAdded for
-- respawns — all filtered to known gear ToolNames). No
-- polling loops. Never mutates inventory: read + warn only.
local traceConns: { [number]: { any } } = {}
local backpackWatched: { [number]: boolean } = {}
local characterHooked: { [number]: boolean } = {}

local function gearToolNameToId(): { [string]: string }
	local map: { [string]: string } = {}
	for _, entry in ipairs(GearConfig.GetAll()) do
		map[entry.ToolName] = entry.Id
	end
	return map
end

local function fullNameOf(inst: Instance?): string
	if inst == nil then
		return 'nil'
	end
	local ok, name = pcall(function()
		return (inst :: Instance):GetFullName()
	end)
	if ok and type(name) == 'string' then
		return name
	end
	return tostring(inst)
end

-- Validity dump of a granted clone (authored-Tool audit):
-- RequiresHandle without a Handle child means the player can
-- hold the instance yet never properly equip/use it.
local function dumpToolValidity(tool: Tool): string
	local parts: { string } = {}
	local function add(label: string, value: string)
		parts[#parts + 1] = label .. '=' .. value
	end
	pcall(function()
		add('name', tool.Name)
		add('class', tool.ClassName)
	end)
	pcall(function()
		add('requiresHandle', tostring(tool.RequiresHandle))
	end)
	pcall(function()
		add('enabled', tostring(tool.Enabled))
	end)
	pcall(function()
		add('canBeDropped', tostring(tool.CanBeDropped))
	end)
	pcall(function()
		add('tooltip', tostring(tool.ToolTip))
	end)
	local handleText = 'handle=missing'
	pcall(function()
		local handle = tool:FindFirstChild('Handle')
		if handle ~= nil then
			handleText = 'handle=' .. handle.ClassName
			if handle:IsA('BasePart') then
				handleText ..= string.format(
					' anchored=%s canCollide=%s transparency=%.2f size=%s',
					tostring(handle.Anchored),
					tostring(handle.CanCollide),
					handle.Transparency,
					tostring(handle.Size)
				)
			else
				handleText ..= ' (NOT-A-BASEPART)'
			end
		end
	end)
	parts[#parts + 1] = handleText
	return table.concat(parts, ' ')
end

local function trackConn(userId: number, conn: any)
	if traceConns[userId] == nil then
		traceConns[userId] = {}
	end
	traceConns[userId][#traceConns[userId] + 1] = conn
end

-- Single explicit lifecycle snapshot: player, gear, identity,
-- live parent, validity, interaction state. Emitted at every
-- lifecycle stage so the log reads as one chain:
-- GRANTED -> (MOVED) -> EQUIPPED -> ACTIVATED -> UNEQUIPPED.
local function lifecycleSnapshot(player: Player, gearId: string, tool: Tool, stage: string)
	local parentName = fullNameOf(tool.Parent)
	local validity = dumpToolValidity(tool)
		Debug.Warn('GearToolLifecycle', ('stage=%s player=%s gearId=%s tool=%s parent=%s %s'):format(
			stage,
			player.Name,
			gearId,
			tool.Name,
			parentName,
			validity
		))
end

-- Character container watch: ChildAdded fires when a Tool is
-- equipped (Backpack -> Character), ChildRemoved when it is
-- unequipped, dropped, or destroyed with the rig. One pair
-- per Character instance (attribute-guarded); the per-player
-- CharacterAdded hook below re-arms it on every respawn.
local function watchCharacterContainer(player: Player, character: Instance?)
	if character == nil then
		return
	end
	local already = false
	pcall(function()
		already = (character :: Instance):GetAttribute('GearTraceWatched') == true
	end)
	if already then
		return
	end
	pcall(function()
		(character :: Instance):SetAttribute('GearTraceWatched', true)
	end)
	local userId = player.UserId
	local names = gearToolNameToId()
	trackConn(
		userId,
		(character :: Model).ChildAdded:Connect(function(child: Instance)
			if names[child.Name] ~= nil and child:IsA('Tool') then
								Debug.Warn('GearToolLifecycle', ('stage=CHARACTER_ADDED player=%s gearId=%s tool=%s parent=%s'):format(
						player.Name,
						names[child.Name],
						child.Name,
						fullNameOf(child.Parent)
					))
			end
		end)
	)
	trackConn(
		userId,
		(character :: Model).ChildRemoved:Connect(function(child: Instance)
			if names[child.Name] ~= nil then
								Debug.Warn('GearToolLifecycle', ('stage=CHARACTER_REMOVED player=%s gearId=%s tool=%s class=%s'):format(
						player.Name,
						names[child.Name],
						child.Name,
						child.ClassName
					))
			end
		end)
	)
end

local function watchCharacterForever(player: Player)
	local userId = player.UserId
	if characterHooked[userId] then
		return
	end
	characterHooked[userId] = true
	pcall(function()
		trackConn(
			userId,
			player.CharacterAdded:Connect(function(character: Model)
				watchCharacterContainer(player, character)
			end)
		)
	end)
	pcall(watchCharacterContainer, player, player.Character)
end

-- One Backpack ChildAdded/ChildRemoved pair per player,
-- filtered to gear ToolNames so unrelated inventory stays
-- silent. Answers "who removed it" at the container level.
local function watchBackpack(player: Player)
	local userId = player.UserId
	if backpackWatched[userId] then
		return
	end
	local ok, backpack = pcall(function()
		return player:FindFirstChildOfClass('Backpack')
	end)
	if not ok or backpack == nil then
		return
	end
	backpackWatched[userId] = true
	local names = gearToolNameToId()
	trackConn(
		userId,
		(backpack :: Backpack).ChildAdded:Connect(function(child: Instance)
			if names[child.Name] ~= nil then
								Debug.Warn('GearShop', ('[ToolTrace] Backpack.ChildAdded gearId=%s tool=%s class=%s parent=%s'):format(
						names[child.Name],
						child.Name,
						child.ClassName,
						fullNameOf(child.Parent)
					))
			end
		end)
	)
	trackConn(
		userId,
		(backpack :: Backpack).ChildRemoved:Connect(function(child: Instance)
			if names[child.Name] ~= nil then
								Debug.Warn('GearShop', ('[ToolTrace] Backpack.ChildRemoved gearId=%s tool=%s class=%s'):format(
						names[child.Name],
						child.Name,
						child.ClassName
					))
			end
		end)
	)
end

-- Attach ancestry tracking to a freshly granted clone (or a
-- found live Tool). Skips instances already watched so
-- respawn ensures never stack connections.
local function watchTool(player: Player, gearId: string, tool: Tool)
	local userId = player.UserId
	local already = false
	pcall(function()
		already = tool:GetAttribute('GearTraceWatched') == true
	end)
	if already then
		return
	end
	pcall(function()
		tool:SetAttribute('GearTraceWatched', true)
	end)
		Debug.Warn('GearShop', ('[ToolTrace] CREATED gearId=%s tool=%s'):format(gearId, tool.Name))
		Debug.Warn('GearShop', ('[ToolTrace] PARENTED tool=%s parent=%s'):format(tool.Name, fullNameOf(tool.Parent)))
		Debug.Warn('GearShop', ('[ToolTrace] VALIDITY gearId=%s %s'):format(gearId, dumpToolValidity(tool)))
	lifecycleSnapshot(player, gearId, tool, 'GRANTED')
	local lastParent = fullNameOf(tool.Parent)
	trackConn(
		userId,
		tool.Equipped:Connect(function()
			lifecycleSnapshot(player, gearId, tool, 'EQUIPPED')
		end)
	)
	trackConn(
		userId,
		tool.Activated:Connect(function()
			lifecycleSnapshot(player, gearId, tool, 'ACTIVATED')
		end)
	)
	trackConn(
		userId,
		tool.Unequipped:Connect(function()
			lifecycleSnapshot(player, gearId, tool, 'UNEQUIPPED')
		end)
	)
	trackConn(
		userId,
		tool.AncestryChanged:Connect(function(_child: Instance, parent: Instance?)
			local nowName = fullNameOf(parent)
						Debug.Warn('GearShop', ('[ToolTrace] ANCESTRY tool=%s old=%s new=%s'):format(tool.Name, lastParent, nowName))
			if parent == nil then
								Debug.Warn('GearShop', ('[ToolTrace][REMOVED] gearId=%s tool=%s lastParent=%s newParent=nil'):format(
						gearId,
						tool.Name,
						lastParent
					))
			end
			lastParent = nowName
		end)
	)
	trackConn(
		userId,
		tool.Destroying:Connect(function()
						Debug.Warn('GearShop', ('[ToolTrace][REMOVED] gearId=%s tool=%s lastParent=%s destroyed=true'):format(
					gearId,
					tool.Name,
					lastParent
				))
		end)
	)
	pcall(watchBackpack, player)
	pcall(watchCharacterForever, player)
end

local function untrackPlayer(userId: number)
	local conns = traceConns[userId]
	if conns ~= nil then
		for _, conn in ipairs(conns) do
			pcall(function()
				(conn :: RBXScriptConnection):Disconnect()
			end)
		end
	end
	traceConns[userId] = nil
	backpackWatched[userId] = nil
	characterHooked[userId] = nil
end

local function formatPrice(price: string): string
	local ok, text = pcall(BigNumber.Format, price)
	if ok and type(text) == 'string' then
		return '$' .. text
	end
	return '$' .. tostring(price)
end

-- --- State snapshot ----------------------------------------------------

function GearShopService.BuildState(player: Player): { [string]: any }?
	if typeof(player) ~= 'Instance' or not player:IsA('Player') then
		return nil
	end
	local userId = player.UserId
	local money = '0'
	if economyServiceRef then
		local ok, value = pcall(economyServiceRef.GetMoney, userId)
		if ok and type(value) == 'string' then
			money = value
		end
	end
	local rebirth = GearShopService.GetPlayerRebirth(userId)
	local data = nil
	if playerServiceRef then
		pcall(function()
			data = playerServiceRef.GetPlayerData(userId)
		end)
	end
	local autoBuy = autoBuyOf(data)
	local gears: { any } = {}
	for _, entry in ipairs(GearConfig.GetAll()) do
		-- OwnedInServer: CURRENT live Tool presence only.
		-- Never the session flag alone, never persistent
		-- data: a rejoin with no provisioned Tool shows
		-- the authoritative price until the Tool exists.
		local ownedInServer = hasLiveTool(player, entry.ToolName)
		gears[#gears + 1] = {
			Id = entry.Id,
			Name = entry.Name,
			Description = entry.Description,
			Price = entry.Price,
			PriceText = formatPrice(entry.Price),
			RequiredRebirth = entry.RequiredRebirth,
			ToolName = entry.ToolName,
			Locked = GearConfig.IsLocked(rebirth, entry.RequiredRebirth),
			Owned = ownedInServer,
			AutoBuy = autoBuy[entry.Id] == true,
		}
	end
	return {
		Money = money,
		MoneyText = formatPrice(money),
		Rebirth = rebirth,
		Gears = gears,
	}
end

local function pushState(player: Player, show: boolean?)
	local state = GearShopService.BuildState(player)
	if not state then
		return
	end
	state.Show = show == true
	pcall(Remotes.FireClient, player, Remotes.Names.GearShopState, state)
end

local function pushResult(player: Player, action: string, gearId: string, success: boolean, err: string?)
	pcall(Remotes.FireClient, player, Remotes.Names.GearShopResult, {
		Action = action,
		GearId = gearId,
		Success = success,
		Error = err,
	})
end

-- --- Purchase ------------------------------------------------------------

-- Normalize AutoBuy preferences on a profile data table:
-- ensures a table exists and every KNOWN gear has an explicit
-- boolean (default false). Unknown keys are preserved;
-- existing true values are never reset (future gears arrive
-- as false). Returns the normalized table (or nil).
function GearShopService.NormalizeAutoBuy(data: any): { [string]: boolean }?
	if type(data) ~= 'table' then
		warn('[GearShop][AutoBuy] missing player profile; cannot normalize')
		return nil
	end
	if type(data.GearAutoBuy) ~= 'table' then
		data.GearAutoBuy = {}
	end
	for _, entry in ipairs(GearConfig.GetAll()) do
		if type(data.GearAutoBuy[entry.Id]) ~= 'boolean' then
			data.GearAutoBuy[entry.Id] = false
		end
	end
	return data.GearAutoBuy
end

-- Normalize the persisted Robux-gear entitlement set
-- ([gearId] = true). Same repair discipline as AutoBuy:
-- missing/wrong-typed becomes {}, existing grants are never
-- reset. Returns the normalized table (or nil).
function GearShopService.NormalizeOwnedRobuxGear(data: any): { [string]: boolean }?
	if type(data) ~= 'table' then
		warn('[GearShop][RobuxGear] missing player profile; cannot normalize')
		return nil
	end
	if type(data.OwnedRobuxGear) ~= 'table' then
		data.OwnedRobuxGear = {}
	end
	return data.OwnedRobuxGear
end

local function ownedRobuxOf(data: any): { [string]: boolean }
	if type(data) == 'table' and type(data.OwnedRobuxGear) == 'table' then
		return data.OwnedRobuxGear
	end
	return {}
end

-- Robux grant path (Shop Developer Product receipt ONLY — never
-- the cash Purchase above, which rejects RobuxOnly entries).
-- Grants the live Tool via the canonical EnsureGearTool, then
-- records the persisted entitlement so rejoins re-grant.
-- Idempotent: already-owned returns true without side effects.
-- Returns false when the Tool asset is missing (receipt must
-- retry later, never consume the purchase).
function GearShopService.GrantRobuxGear(player: Player, gearId: string): boolean
	if not Validation.LivePlayer(player) then
		return false
	end
	local entry = GearConfig.FindGear(gearId)
	if not entry then
		warn(('[GearShop][RobuxGear][ERROR] unknown GearId=%s'):format(tostring(gearId)))
		return false
	end
	local granted = false
	pcall(function()
		granted = GearShopService.EnsureGearTool(player, gearId) == true
	end)
	if not granted then
		warn(('[GearShop][RobuxGear] grant failed GearId=%s player=%s (asset missing?)'):format(entry.Id, player.Name))
		return false
	end
	-- Session ownership IS the ownership state (same table
	-- cash purchases commit to): without this flag, equip,
	-- respawn re-grants, and auto-buy recognition would all
	-- treat the Robux bat as unowned. The Shop grants the
	-- GEAR — never a parallel Shop-only copy.
	if ownedBy[player.UserId] == nil then
		ownedBy[player.UserId] = {}
	end
	ownedBy[player.UserId][gearId] = true
	if playerServiceRef then
		pcall(function()
			local data = playerServiceRef.GetPlayerData(player.UserId)
			local owned = GearShopService.NormalizeOwnedRobuxGear(data)
			if owned then
				owned[gearId] = true
			end
		end)
	end
	Debug.Log('GS', 'robux gear granted', { gearId = entry.Id, player = player.Name })
	return true
end

-- Idempotent single-gear grant: ensures exactly one live Tool
-- (matched by exact Tool Name) exists in Backpack or
-- Character. Checks BOTH containers so an equipped Tool is
-- never duplicated. Granted clones are marked
-- CanBeDropped = false so death returns them to the Backpack
-- instead of dropping a Workspace copy (which would look like
-- a duplicate on the next ensure). Never charges, never
-- duplicates, never yields on a timer: if neither Backpack
-- nor Character exists yet the grant fails loudly and the
-- caller decides (purchase rolls back + refunds; respawn
-- re-runs this via CharacterAdded). No polling loops.
-- Returns true when the Tool is present afterwards.
function GearShopService.EnsureGearTool(player: Player, gearId: string): boolean
	if not Validation.LivePlayer(player) then
		return false
	end
	local entry = GearConfig.FindGear(gearId)
	if not entry then
		warn(('[GearShop][Grant][ERROR] unknown GearId=%s'):format(tostring(gearId)))
		return false
	end
		Debug.Warn('GearShop', ('[Grant] player=%s gearId=%s'):format(player.Name, entry.Id))
	local status = resolveToolStatus(entry.ToolName)
	local source = status.found
	local expectedPath = toolsPathFor(entry.ToolName)
	if source == nil then
		if status.class then
			warn(
				('[GearShop][Grant][ERROR] source is not a Tool GearId=%s source=%s class=%s (expected Tool)'):format(
					entry.Id,
					expectedPath,
					tostring(status.class)
				)
			)
		else
			warn(('[GearShop][Grant][ERROR] missing Tool source GearId=%s source=%s'):format(entry.Id, expectedPath))
		end
		return false
	end
		Debug.Warn('GearShop', ('[Grant] GearId=%s source=%s sourceClass=Tool'):format(entry.Id, expectedPath))
	if hasLiveTool(player, (source :: Tool).Name) then
				Debug.Warn('GearShop', ('[Grant] ownership confirmed GearId=%s (already provisioned)'):format(entry.Id))
		pcall(function()
			local backpack = player:FindFirstChildOfClass('Backpack')
			local character = player.Character
			for _, container in ipairs({ backpack, character }) do
				if container ~= nil then
					local live = (container :: Instance):FindFirstChild((source :: Tool).Name)
					if live ~= nil and live:IsA('Tool') then
						watchTool(player, entry.Id, live)
						break
					end
				end
			end
		end)
		return true
	end
	local backpack = player:FindFirstChildOfClass('Backpack')
	local character = player.Character
	warn(
		('[GearShop][Grant] clone=%s cloneClass=Tool backpack=%s parentBefore=nil'):format(
			(source :: Tool).Name,
			if backpack ~= nil then 'present' else 'missing'
		)
	)
	local destination = 'nowhere'
	local grantedClone: Tool? = nil
	local ok, err = pcall(function()
		local gearClone = (source :: Tool):Clone()
		assert(gearClone ~= nil, 'clone-nil')
		assert(gearClone:IsA('Tool'), 'clone-not-tool')
		gearClone.Name = (source :: Tool).Name
		gearClone.CanBeDropped = false
		if backpack then
			gearClone.Parent = backpack
			destination = 'Backpack'
		elseif character then
			gearClone.Parent = character
			destination = 'Character'
		else
			gearClone:Destroy()
			error('grant-nowhere')
		end
		if gearClone.Parent ~= backpack and gearClone.Parent ~= character then
			error('parent-mismatch')
		end
		grantedClone = gearClone
	end)
	if not ok then
		warn(
			('[GearShop][Grant][ERROR] failed to grant GearId=%s player=%s: %s'):format(
				entry.Id,
				player.Name,
				tostring(err)
			)
		)
		return false
	end
		Debug.Warn('GearShop', ('[Grant] parented Tool to %s player=%s'):format(destination, player.Name))
	Debug.Warn('GearShop', ('[Grant] parentAfter=Player.%s'):format(destination))
	local verified = hasLiveTool(player, (source :: Tool).Name)
		Debug.Warn('GearShop', ('[Grant] verified=%s GearId=%s'):format(tostring(verified), entry.Id))
	if not verified then
		warn(('[GearShop][Grant][ERROR] Tool parent failed GearId=%s player=%s'):format(entry.Id, player.Name))
		return false
	end
		Debug.Warn('GearShop', ('[Grant] ownership confirmed GearId=%s'):format(entry.Id))
	if grantedClone ~= nil then
		pcall(watchTool, player, entry.Id, grantedClone)
		pcall(watchBackpack, player)
	end
	return true
end

-- Idempotent Tool provisioning for every session-owned gear.
-- Thin loop over EnsureGearTool (single source of grant
-- truth). Used by purchase verification, join AutoBuy, AND
-- respawn. Never charges, never duplicates.
function GearShopService.EnsureOwnedTools(player: Player): number
	if not Validation.LivePlayer(player) then
		return 0
	end
	local userId = player.UserId
	local granted = 0
	for _, entry in ipairs(GearConfig.GetAll()) do
		if isOwned(userId, entry.Id) then
			if GearShopService.EnsureGearTool(player, entry.Id) then
				granted += 1
			end
		end
	end
	return granted
end

-- Per-player bat trace (always on: proves multiplayer
-- isolation in output — every line names its player).
local function _batlog(player: Player, action: string, detail: string?)
	Debug.Log('BatSystem', ('player=%s action=%s %s'):format(player.Name, action, detail or ''))
end

local function _ownedList(userId: number): string
	local ids: { string } = {}
	pcall(function()
		for id, _ in pairs(ownedBy[userId] or {}) do
			ids[#ids + 1] = id
		end
	end)
	table.sort(ids)
	return '{' .. table.concat(ids, ',') .. '}'
end

-- Grant the permanent starting bat (session ownership + live
-- Tool). Never charges, never notifies: it is a fallback, not
-- a purchase. Returns true when the Tool is present after.
function GearShopService.EnsureDefaultBat(player: Player): boolean
	if not Validation.LivePlayer(player) then
		return false
	end
	local userId = player.UserId
	local gearId = GearShopService.DefaultGearId()
	if ownedBy[userId] == nil then
		ownedBy[userId] = {}
	end
	ownedBy[userId][gearId] = true
	return GearShopService.EnsureGearTool(player, gearId) == true
end

-- A Tool counts as a bat iff the combat catalog knows its
-- exact ToolName (GalaxyBat included — same rule as combat
-- and client input gating). Coils/cloaks are never bats, so
-- cleanup below can never touch unrelated gear. Never throws.
local function _isBatToolName(toolName: string): boolean
	if type(toolName) ~= 'string' or toolName == '' then
		return false
	end
	local known = false
	pcall(function()
		known = GearConfig.Combat.GetByToolName(toolName) ~= nil
	end)
	return known == true
end

-- Server-authoritative equip: move the player's OWN live Tool
-- into their OWN Character (Backpack -> Character). Only ever
-- touches the acting player's containers, so Player A's equip
-- can never affect Player B. Records equippedBy on success.
-- Never throws; returns whether the Tool ended up equipped.
function GearShopService.EquipGear(player: Player, gearId: string): boolean
	if not Validation.LivePlayer(player) then
		return false
	end
	if type(gearId) ~= 'string' or gearId == '' then
		return false
	end
	local userId = player.UserId
	local entry = GearConfig.FindGear(gearId)
	if not entry then
		return false
	end
	-- Default bat self-heals ownership (always available);
	-- anything else must already be session-owned.
	if gearId == GearShopService.DefaultGearId() then
		if ownedBy[userId] == nil then
			ownedBy[userId] = {}
		end
		ownedBy[userId][gearId] = true
	elseif not isOwned(userId, gearId) then
		_batlog(player, 'equip-rejected', ('gearId=%s reason=not-owned'):format(gearId))
		return false
	end
	local toolName = entry.ToolName
	local character = player.Character
	local backpack = player:FindFirstChildOfClass('Backpack')
	local equipped = false
	pcall(function()
		-- Already equipped: record + done (never duplicate).
		local heldNow = false
		if character ~= nil then
			local held = character:FindFirstChild(toolName)
			heldNow = held ~= nil and held:IsA('Tool')
		end
		local stowedNow = false
		if backpack ~= nil then
			local stowed = backpack:FindFirstChild(toolName)
			stowedNow = stowed ~= nil and stowed:IsA('Tool')
		end
		if not heldNow and not stowedNow then
			-- Target nowhere: touch nothing (must not strip
			-- the currently equipped bat for a missing one).
			return
		end
		-- Single-equipped invariant: exactly one bat may sit
		-- in the Character. Park every OTHER live Tool back
		-- in the Backpack first (their home), so replacement
		-- can never stack two equipped bats — GalaxyBat,
		-- DefaultBat, and shop bats all obey the same rule.
		if character ~= nil then
			for _, child in ipairs(character:GetChildren()) do
				if child:IsA('Tool') and child.Name ~= toolName then
					local bp = player:FindFirstChildOfClass('Backpack')
					if bp ~= nil then
						child.Parent = bp
					end
				end
			end
		end
		if heldNow then
			equipped = true
		end
		if not equipped and backpack ~= nil then
			local stowed = backpack:FindFirstChild(toolName)
			if stowed ~= nil and stowed:IsA('Tool') then
				local humanoid: Instance? = nil
				if character ~= nil then
					humanoid = character:FindFirstChildOfClass('Humanoid')
				end
				if humanoid ~= nil and (humanoid :: Humanoid).Health > 0 then
					pcall(function()
						(humanoid :: Humanoid):EquipTool(stowed :: Tool)
					end)
				end
				-- Fallback (no live humanoid yet): parent
				-- directly; CharacterAdded re-runs this path.
				if (stowed :: Tool).Parent ~= character and character ~= nil then
					(stowed :: Tool).Parent = character
				end
			end
		end
		if character ~= nil then
			local held = character:FindFirstChild(toolName)
			equipped = held ~= nil and held:IsA('Tool')
		end
		-- Duplicate-bat cleanup (Backpack holds at most one
		-- copy per bat ToolName): grant races and death edges
		-- can strand extras, and the Character park above can
		-- double a Backpack copy. Ownership flags are never
		-- touched — only surplus physical Tools go. Non-bat
		-- Tools are never matched, never moved, never
		-- destroyed.
		if backpack ~= nil then
			local seen: { [string]: boolean } = {}
			for _, child in ipairs(backpack:GetChildren()) do
				if child:IsA('Tool') and _isBatToolName(child.Name) then
					if seen[child.Name] then
						pcall(function()
							(child :: Tool):Destroy()
						end)
					else
						seen[child.Name] = true
					end
				end
			end
		end
	end)
	if equipped then
		equippedBy[userId] = gearId
		-- Funnel: first REAL equip. The default bat is free
		-- equipment (auto-equipped on spawn) — never a
		-- purchase/equip milestone.
		if gearId ~= GearShopService.DefaultGearId() then
			pcall(function()
				FunnelService:LogStep(player, 'Gear', 'FirstGearEquipped', { gear_id = gearId })
			end)
		end
		_batlog(player, 'equipped', ('gearId=%s owned=%s'):format(gearId, _ownedList(userId)))
	else
		_batlog(player, 'equip-deferred', ('gearId=%s reason=no-character-yet'):format(gearId))
	end
	return equipped
end

-- Respawn entry (bootstrap CharacterAdded calls this INSTEAD
-- of bare EnsureOwnedTools): re-grant session tools, then
-- re-equip the session choice (preserved across respawns in
-- the SAME server — only a fresh join resets to DefaultBat).
-- Never duplicates: EquipGear no-ops when already held.
function GearShopService.OnCharacterSpawned(player: Player)
	if not Validation.LivePlayer(player) then
		return
	end
	pcall(GearShopService.EnsureOwnedTools, player)
	local userId = player.UserId
	local target = equippedBy[userId]
	if type(target) ~= 'string' or not isOwned(userId, target) then
		target = GearShopService.DefaultGearId()
		pcall(GearShopService.EnsureDefaultBat, player)
	end
	pcall(GearShopService.EquipGear, player, target)
end

-- Inner commit. Never throws (all fallible steps guarded);
-- returns { success, error?, shortfall? }.
-- Flow: VALIDATE -> DEDUCT -> COMMIT session ownership ->
-- GRANT actual Tool -> VERIFY Tool exists -> SUCCESS.
-- The UI Owned flag is derived from live Tool presence, so
-- a grant failure must never report success: the session
-- flag is rolled back and the debit refunded (GearRefund).
local function purchaseInner(player: Player, entry: any, quiet: boolean): { [string]: any }
	local userId = player.UserId
	local gearId = tostring(entry.Id)
	if isOwned(userId, gearId) then
		-- Session already owns it: top up the live Tool if it
		-- was lost, then report already-owned (no double
		-- charge, no duplicate). An explicit Buy press also
		-- (re-)equips the exact bat.
		pcall(GearShopService.EnsureGearTool, player, gearId)
		pcall(GearShopService.EquipGear, player, gearId)
		if not quiet then
			pcall(NotificationService.NotifyWarning, player, 'Gear_AlreadyOwned', {})
		end
		return { success = false, error = 'already-owned' }
	end
	if hasLiveTool(player, entry.ToolName) then
		-- Tool present without a session flag (admin grant /
		-- respawn edge): adopt the session flag so respawns
		-- keep it, then report already-owned. No charge.
		if ownedBy[userId] == nil then
			ownedBy[userId] = {}
		end
		ownedBy[userId][gearId] = true
		if not quiet then
			pcall(NotificationService.NotifyWarning, player, 'Gear_AlreadyOwned', {})
		end
		return { success = false, error = 'already-owned' }
	end
	if entry.RobuxOnly == true then
		-- Robux-exclusive gear (Galaxy Bat) is never cash
		-- purchasable: granting flows only through the Shop
		-- Developer Product receipt (GrantRobuxGear). A cash
		-- purchase must fail loudly, never debit.
		if not quiet then
			pcall(NotificationService.NotifyWarning, player, 'Gear_RobuxOnly', {})
		end
		return { success = false, error = 'robux-only' }
	end
	if GearConfig.IsLocked(GearShopService.GetPlayerRebirth(userId), entry.RequiredRebirth) then
		if not quiet then
			pcall(NotificationService.NotifyWarning, player, 'Gear_LockedRebirth', {
				Required = entry.RequiredRebirth,
				GearName = entry.Name,
			})
		end
		return { success = false, error = 'locked-rebirth' }
	end
	local tool = GearShopService.ResolveTool(entry.ToolName)
	if not tool then
		local status = GearShopService.ToolStatus(entry.ToolName)
		if status.class then
						Debug.Warn('GearShop', ('Tool wrong class GearId=%s ToolName=%s path=%s class=%s (expected Tool)'):format(
					gearId,
					tostring(entry.ToolName),
					toolsPathFor(entry.ToolName),
					tostring(status.class)
				))
		else
			warn(
				('[GearShop] Missing Tool GearId=%s ToolName=%s path=%s'):format(
					gearId,
					tostring(entry.ToolName),
					toolsPathFor(entry.ToolName)
				)
			)
		end
		if not quiet then
			pcall(NotificationService.NotifyWarning, player, 'Gear_ToolUnavailable', {})
		end
		return { success = false, error = 'tool-missing' }
	end
	if not economyServiceRef then
		warn(('[GearShop] EconomyService unwired; rejecting purchase GearId=%s'):format(gearId))
		return { success = false, error = 'service-not-ready' }
	end
	local spendOk, result = pcall(economyServiceRef.TrySpendMoney, userId, entry.Price, 'GearPurchase')
	if not spendOk or type(result) ~= 'table' or result.Success ~= true then
		local code = (type(result) == 'table' and result.Code) or 'unknown'
		if code == 'insufficient' then
			local shortfall = '0'
			pcall(function()
				local money = economyServiceRef.GetMoney(userId)
				shortfall = BigNumber.Subtract(entry.Price, money)
			end)
			if not quiet then
				-- NOTE: Amount is the RAW BigNumber string.
				-- NotificationService owns {Amount} formatting;
				-- a preformatted value sanitizes to '$0'.
				pcall(NotificationService.NotifyWarning, player, 'Gear_InsufficientCash', {
					Amount = shortfall,
					GearName = entry.Name,
				})
			end
			return { success = false, error = 'insufficient-money' }
		end
		warn(('[GearShop] Purchase debit failed GearId=%s code=%s'):format(gearId, tostring(code)))
		return { success = false, error = 'debit-failed' }
	end
	-- Commit: debit landed. Mark session-owned, grant the
	-- ACTUAL Tool, then VERIFY it exists before reporting
	-- success. A failed grant rolls back the session flag
	-- and refunds (GearRefund) so state never fakes Owned.
	if ownedBy[userId] == nil then
		ownedBy[userId] = {}
	end
	ownedBy[userId][gearId] = true
	local grantOk, granted = pcall(GearShopService.EnsureGearTool, player, gearId)
	if not grantOk then
		warn(
			('[GearShop][Grant][ERROR] ensure threw after debit GearId=%s user=%s: %s'):format(
				gearId,
				tostring(userId),
				tostring(granted)
			)
		)
		granted = false
	end
	if granted ~= true or not hasLiveTool(player, entry.ToolName) then
		warn(('[GearShop][Grant][ERROR] Tool parent failed GearId=%s player=%s; refunding'):format(gearId, player.Name))
		if ownedBy[userId] ~= nil then
			ownedBy[userId][gearId] = nil
		end
		if economyServiceRef then
			pcall(economyServiceRef.AddMoney, userId, entry.Price, 'GearRefund', { ApplyMultiplier = false })
		end
		if not quiet then
			pcall(NotificationService.NotifyWarning, player, 'Gear_ToolUnavailable', {})
		end
		return { success = false, error = 'grant-failed' }
	end
	if not quiet then
		pcall(NotificationService.NotifySuccess, player, 'Gear_Success', { GearName = entry.Name })
	end
	-- Funnel: cash purchase committed above (debit + grant +
	-- verify all succeeded; Robux-only Galaxy Bat can never
	-- reach here — it flows through the Shop receipt). Logged
	-- BEFORE the best-effort equip below so the Gear funnel
	-- fires Purchased(1) -> Equipped(2) in definition order.
	-- The free Default Bat is structurally excluded (same rule
	-- as the equip hook): it is never a purchase milestone
	-- even if a grant path ever reaches this tail for it.
	if gearId ~= GearShopService.DefaultGearId() then
		pcall(function()
			FunnelService:LogStep(player, 'Gear', 'FirstGearPurchased', { gear_id = gearId })
		end)
	end
	-- Atomic purchase-equip: ownership committed and the live
	-- Tool verified above, so equip THAT EXACT bat now (never
	-- first-owned / last-configured). Best-effort: a missing
	-- character defers to CharacterAdded, never fails the sale.
	pcall(GearShopService.EquipGear, player, gearId)
	Debug.Log('GS', 'purchase committed', { userId = tostring(userId), gearId = gearId })
	return { success = true }
end

-- Validated entry point. Serializes per player; the mutex can
-- never stick (cleared on every exit, including throws).
function GearShopService.Purchase(player: Player, gearId: string, quiet: boolean?): { [string]: any }
	if not Validation.LivePlayer(player) then
		return { success = false, error = 'invalid-player' }
	end
	local entry = GearConfig.FindGear(gearId)
	if not entry then
		warn(('[GearShop] Purchase rejected: unknown GearId=%s'):format(tostring(gearId)))
		if not quiet then
			pcall(NotificationService.NotifyWarning, player, 'Gear_InvalidGear', {})
		end
		return { success = false, error = 'invalid-gear' }
	end
	local userId = player.UserId
	if busyBy[userId] then
		if not quiet then
			pcall(NotificationService.NotifyWarning, player, 'Gear_Busy', {})
		end
		return { success = false, error = 'in-progress' }
	end
	busyBy[userId] = true
	local ok, result = pcall(purchaseInner, player, entry, quiet == true)
	busyBy[userId] = nil
	if not ok then
		warn(('[GearShop] Purchase errored GearId=%s: %s'):format(tostring(entry.Id), tostring(result)))
		return { success = false, error = 'internal' }
	end
	return result
end

-- --- AutoBuy ---------------------------------------------------------------

function GearShopService.SetAutoBuy(player: Player, gearId: string, enabled: boolean): { [string]: any }
	if not Validation.LivePlayer(player) then
		return { success = false, error = 'invalid-player' }
	end
	local entry = GearConfig.FindGear(gearId)
	if not entry then
		warn(('[GearShop] SetAutoBuy rejected: unknown GearId=%s'):format(tostring(gearId)))
		return { success = false, error = 'invalid-gear' }
	end
	-- Strict boolean: the strings "true"/"false", numbers, and
	-- nil are REJECTED (never coerced) — the server owns the
	-- final boolean.
	if type(enabled) ~= 'boolean' then
		warn(('[GearShop][AutoBuy] rejected non-boolean GearId=%s type=%s'):format(tostring(entry.Id), type(enabled)))
		return { success = false, error = 'invalid-value' }
	end
	if not playerServiceRef then
		return { success = false, error = 'service-not-ready' }
	end
	local userId = player.UserId
	local ok, err = pcall(function()
		local data = playerServiceRef.GetPlayerData(userId)
		if type(data) ~= 'table' then
			error('no-profile')
		end
		GearShopService.NormalizeAutoBuy(data)
		if enabled then
			data.GearAutoBuy[gearId] = true
		else
			data.GearAutoBuy[gearId] = false
		end
	end)
	if not ok then
		warn(('[GearShop] SetAutoBuy write failed GearId=%s: %s'):format(tostring(entry.Id), tostring(err)))
		return { success = false, error = 'internal' }
	end
		Debug.Warn('GearShop', ('[AutoBuy] GearId=%s player=%s enabled=%s'):format(
			tostring(entry.Id),
			player.Name,
			tostring(enabled)
		))
	pushState(player)
	-- Enabling AutoBuy immediately attempts the normal
	-- validated purchase pipeline (quiet: an unaffordable gear
	-- stays preference-only with no toast spam). Disabling
	-- never interrupts an in-flight purchase.
	if enabled and not isOwned(userId, gearId) then
		local result = GearShopService.Purchase(player, gearId, true)
		if result.success then
			pushState(player)
		end
	end
	return { success = true }
end

-- Join-time flow (runs EXACTLY ONCE per server session per
-- player — readyBy guard, cleared on leave):
--   1. DefaultBat granted + equipped (safe fallback while
--      auto-buy resolves; stays if auto-buy buys nothing).
--   2. Each enabled auto-buy gear attempted once, silently
--      (no toasts — a fresh join is not the place for a toast
--      stack). Every success equips THAT bat, so the last
--      (priciest, config-ordered) affordable bat wins.
--   3. Persisted Robux entitlements re-granted (no equip
--      change).
-- Runs only after the profile is loaded (bootstrap calls this
-- post-MarkLoaded).
function GearShopService.OnPlayerReady(player: Player)
	if not Validation.LivePlayer(player) then
		return
	end
	local userId = player.UserId
	if readyBy[userId] == true then
		return
	end
	readyBy[userId] = true
	if GearShopService.EnsureDefaultBat(player) then
		pcall(GearShopService.EquipGear, player, GearShopService.DefaultGearId())
	end
	_batlog(player, 'join-default', ('equipped=%s'):format(tostring(equippedBy[userId])))
	local data = nil
	if playerServiceRef then
		pcall(function()
			data = playerServiceRef.GetPlayerData(userId)
		end)
	end
	GearShopService.NormalizeAutoBuy(data)
	local autoBuy = autoBuyOf(data)
	local attempted = 0
	for _, entry in ipairs(GearConfig.GetAll()) do
		if autoBuy[entry.Id] == true and not isOwned(userId, entry.Id) then
			local result = GearShopService.Purchase(player, entry.Id, true)
			if result.success then
				attempted += 1
			else
				Debug.Log('GS', 'autobuy skipped', {
					userId = tostring(userId),
					gearId = entry.Id,
					error = tostring(result.error),
				})
			end
		end
	end
	-- Robux entitlements survive rejoin (persisted set above);
	-- re-grant each owned Robux gear idempotently. Missing Tool
	-- assets warn here and retry next join (receipt semantics
	-- stay in ShopService).
	local robuxOwned = ownedRobuxOf(data)
	for gearId, owned in pairs(robuxOwned) do
		if owned == true and not isOwned(userId, gearId) then
			local ok = false
			pcall(function()
				ok = GearShopService.EnsureGearTool(player, gearId) == true
			end)
			if ok then
				-- Rehydrate the session flag (same table cash
				-- purchases and receipts commit to): without it,
				-- equip, auto-buy recognition, and the
				-- already-owned path all treat the re-granted
				-- Robux bat as unowned after every rejoin.
				if ownedBy[userId] == nil then
					ownedBy[userId] = {}
				end
				ownedBy[userId][gearId] = true
				attempted += 1
			else
				Debug.Log('GS', 'robux re-grant skipped', { userId = tostring(userId), gearId = tostring(gearId) })
			end
		end
	end
	if attempted > 0 then
		pushState(player)
	end
end

function GearShopService.OpenShop(player: Player)
	if not Validation.LivePlayer(player) then
		return
	end
	-- Provision the runtime row template first: the client
	-- renders rows from PlayerGui, and ServerStorage is
	-- unreadable to it. Idempotent; self-heals respawns.
	GearShopService.EnsureRuntimeTemplate(player)
	pushState(player, true)
end

function GearShopService.ForgetPlayer(userId: number)
	if type(userId) ~= 'number' then
		return
	end
	ownedBy[userId] = nil
	equippedBy[userId] = nil
	readyBy[userId] = nil
	busyBy[userId] = nil
	pcall(untrackPlayer, userId)
	Debug.Log('GS', 'ForgetPlayer: session cleared', { userId = tostring(userId) })
end

-- --- Remote ingress --------------------------------------------------------

local function handleAction(player: Player, payload: any)
	local ok, err = pcall(function()
		if not Validation.LivePlayer(player) then
			return
		end
		if type(payload) ~= 'table' or type(payload.Action) ~= 'string' then
			warn(('[GearShop] Malformed action from player=%s'):format(player.Name))
			return
		end
		if payload.Action == 'Purchase' then
			local result = GearShopService.Purchase(player, payload.GearId)
			pushResult(player, 'Purchase', tostring(payload.GearId), result.success == true, result.error)
			pushState(player)
		elseif payload.Action == 'Equip' then
			-- Switching between owned bats (Galaxy <-> cash bats
			-- <-> Default): the ONE equip path, same invariant
			-- as receipt/purchase auto-equip (exactly one Tool
			-- in Character, everything else parked). Rejects
			-- unknown or unowned ids; never charges, never
			-- grants — ownership must already exist.
			local gearId = payload.GearId
			local equipped = false
			pcall(function()
				equipped = GearShopService.EquipGear(player, gearId) == true
			end)
			pushResult(player, 'Equip', tostring(gearId), equipped, if equipped then nil else 'equip-failed')
			pushState(player)
		elseif payload.Action == 'SetAutoBuy' then
			local result = GearShopService.SetAutoBuy(player, payload.GearId, payload.Enabled)
			pushResult(player, 'SetAutoBuy', tostring(payload.GearId), result.success == true, result.error)
		else
			warn(('[GearShop] Unknown action=%s from player=%s'):format(tostring(payload.Action), player.Name))
		end
	end)
	if not ok then
		warn(('[GearShop] Action handler errored: %s'):format(tostring(err)))
	end
end

-- --- Runtime template (server provisions, client consumes) --------------------

-- The authoritative row template lives server-only at
-- ServerStorage.Assets.Ui.GearShop.GearTemplate. The client
-- can never read ServerStorage, so the server clones it once
-- per PlayerGui lifecycle into the player's own
-- GearShop.ScrollingFrame as 'GearTemplate' (hidden
-- prototype; rows are separate GearId-stamped clones). Runs
-- on every open (idempotent) so respawns and first joins
-- self-heal. Returns true when a usable template exists
-- afterwards. Never throws.
local function resolveAuthoritativeTemplate(): Instance?
	local assets = ServerStorage:FindFirstChild('Assets')
	local ui = assets and assets:FindFirstChild('Ui') or nil
	local shop = ui and ui:FindFirstChild('GearShop') or nil
	local template = shop and shop:FindFirstChild('GearTemplate') or nil
	if template == nil then
		return nil
	end
	return template
end

local function findPlayerShopGui(player: Player): Instance?
	local ok, gui = pcall(function()
		return player:FindFirstChildOfClass('PlayerGui')
	end)
	if not ok or gui == nil then
		return nil
	end
	return (gui :: PlayerGui):FindFirstChild('GearShop', true)
end

function GearShopService.EnsureRuntimeTemplate(player: Player): boolean
	local ok, ready = pcall(function()
		if not Validation.LivePlayer(player) then
			return false
		end
		local shopGui = findPlayerShopGui(player)
		if shopGui == nil then
			warn(
				('[GearShop] PlayerGui GearShop missing for player=%s; cannot provision runtime template'):format(
					player.Name
				)
			)
			return false
		end
		local scrolling = shopGui:FindFirstChild('ScrollingFrame', true)
		if scrolling == nil then
			warn(('[GearShop] ScrollingFrame missing in GearShop GUI for player=%s'):format(player.Name))
			return false
		end
		local existing = scrolling:FindFirstChild('GearTemplate')
		if existing ~= nil and existing:GetAttribute('GearId') == nil then
			return true
		end
		local source = resolveAuthoritativeTemplate()
		if source == nil then
			warn('[GearShop] ERROR authoritative GearTemplate missing at ServerStorage.Assets.Ui.GearShop.GearTemplate')
			return false
		end
		local clone = (source :: Instance):Clone()
		clone.Name = 'GearTemplate'
		if clone:IsA('GuiObject') then
			clone.Visible = false
		end
		clone.Parent = scrolling
				Debug.Warn('GearShop', ('Runtime GearTemplate cloned to %s'):format(clone:GetFullName()))
		return true
	end)
	if not ok then
		warn(('[GearShop] Runtime template provisioning failed: %s'):format(tostring(ready)))
		return false
	end
	return ready == true
end

-- --- Previews (server publishes, client consumes) -----------------------------

-- Publish script-stripped Tool clones to ReplicatedStorage ONCE
-- at boot so ViewportFrames can preview gear the client is
-- never allowed to read from ServerStorage. The live Tools
-- stay server-side; these are display shells only.
local function publishPreviews()
	local ok, err = pcall(function()
		local folder = ReplicatedStorage:FindFirstChild(PREVIEW_FOLDER_NAME)
		if not folder then
			folder = Instance.new('Folder')
			folder.Name = PREVIEW_FOLDER_NAME
			folder.Parent = ReplicatedStorage
		end
		for _, entry in ipairs(GearConfig.GetAll()) do
			if (folder :: Folder):FindFirstChild(entry.Id) then
				continue
			end
			local tool = GearShopService.ResolveTool(entry.ToolName)
			if not tool then
				continue
			end
			local preview = (tool :: Tool):Clone()
			for _, desc in ipairs(preview:GetDescendants()) do
				if desc:IsA('Script') or desc:IsA('LocalScript') then
					desc:Destroy()
				end
			end
			preview.Name = entry.Id
			preview.Parent = folder
		end
	end)
	if not ok then
		warn(('[GearShop] Preview publish failed: %s'):format(tostring(err)))
	end
end

-- --- Shop prompt ---------------------------------------------------------------

local function wireShopPrompt()
	local ok, err = pcall(function()
		local map = Workspace:FindFirstChild('Map')
		local shop = map and map:FindFirstChild('Shop') or nil
		local part = shop and shop:FindFirstChild('PromptPart') or nil
		if part == nil or not part:IsA('BasePart') then
			warn('[GearShop] PromptPart missing (expected Workspace.Map.Shop.PromptPart); shop has no world entry')
			return
		end
		local prompt = (part :: BasePart):FindFirstChildOfClass('ProximityPrompt')
		if not prompt then
			local created = Instance.new('ProximityPrompt')
			created.ActionText = PromptConfig.GearShop.ActionText
			created.HoldDuration = PromptConfig.GearShop.HoldDuration
			created.MaxActivationDistance = PromptConfig.GearShop.MaxActivationDistance
			created.RequiresLineOfSight = PromptConfig.GearShop.RequiresLineOfSight
			created.Parent = part
			prompt = created
		end
		(prompt :: ProximityPrompt).Triggered:Connect(function(player: Player)
			GearShopService.OpenShop(player)
		end)
	end)
	if not ok then
		warn(('[GearShop] Shop prompt wiring failed: %s'):format(tostring(err)))
	end
end

-- --- Init --------------------------------------------------------------------------

function GearShopService.Init()
	if started then
		return
	end
	started = true
	for _, issue in ipairs(GearConfig.ValidateLive()) do
		warn(('[GearShop] Config issue: %s'):format(issue))
	end
	publishPreviews()
	wireShopPrompt()
	local ok, err = pcall(function()
		local folder = Remotes.GetFolder()
		local remote = folder:WaitForChild(Remotes.Names.GearShopAction, 10)
		assert(remote and remote:IsA('RemoteEvent'), 'GearShopAction remote missing')
		local actionRemote = remote :: RemoteEvent
		actionRemote.OnServerEvent:Connect(handleAction)
	end)
	if not ok then
		warn(('[GearShop] Action remote wiring failed: %s'):format(tostring(err)))
	end
	Debug.Log('GS', 'Init done')
end

function GearShopService._TestReset()
	for key in pairs(ownedBy) do
		ownedBy[key] = nil
	end
	for key in pairs(equippedBy) do
		equippedBy[key] = nil
	end
	for key in pairs(readyBy) do
		readyBy[key] = nil
	end
	for key in pairs(busyBy) do
		busyBy[key] = nil
	end
	for key in pairs(traceConns) do
		pcall(untrackPlayer, key)
	end
	for key in pairs(backpackWatched) do
		backpackWatched[key] = nil
	end
	for key in pairs(characterHooked) do
		characterHooked[key] = nil
	end
end

return table.freeze(GearShopService)
