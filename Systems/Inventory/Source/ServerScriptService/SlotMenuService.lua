--!strict
--!native
--[[
	SlotMenuService
	=================
	Server side of the slot interaction menus
	(MainGui.UpgradesFrame, opened from the slot's
	MenuPart.MenuGui UpgradeButton). Player-facing and
	owner-validated per request (NOT admin-gated — every player
	uses their own slots' menus).

	Two endpoints, upgrade-only (selling lives on the animal's
	Sell prompt; eggs are not sellable):

	  * SlotMenuRequest { SlotId } -> SlotMenuState snapshot.
	    Preview data ONLY: identity, level, effective generation,
	    pool, and upgrade cost preview, all resolved here from
	    authoritative state (AnimalService, UpgradeService,
	    AnimalStats, ModifierService). The client renders text;
	    it can never submit values.
	  * SlotMenuAction { SlotId, OccupantId, Action = 'Upgrade' }
	    -> SlotMenuResult (+ NewLevel/Cost on success). Upgrade
	    confirm: animal-only, routed to UpgradeService
	    (atomic debit + Level += 1). Stale/Egg/wrong-owner
	    contexts reject with nothing moved. Any non-Upgrade
	    action (including forged sell confirms) rejects with
	    no money moved.
	    SlotMenuResult { SlotId, Success, Error? } lets the client
	    close + clear immediately instead of guessing.

	No loops, no scans, no per-slot state — request/response only.
	Throttle: 0.5s per player per endpoint (same rule as Debug).
]]

local AnimalConfig = require(script.Parent.Parent.ReplicatedStorage.Config.Creatures.Animals)
local LevelConfig = require(script.Parent.Parent.ReplicatedStorage.Config.Creatures.Progression)
local StandConfig = require(script.Parent.Parent.ReplicatedStorage.Config.World.Bases).Stands
local Security = require(script.Parent.Parent.ReplicatedStorage.Config.Systems.Security)
local BigNumber = require(script.Parent.Parent.ReplicatedStorage.Utility.BigNumber)
local AnimalStats = require(script.Parent.Parent.ReplicatedStorage.Utility.AnimalStats)
local Remotes = require(script.Parent.Parent.ReplicatedStorage.Utility.Remotes)
local Debug = require(script.Parent.Parent.ReplicatedStorage.Utility.Debug)
local Validation = require(script.Parent.Parent.ReplicatedStorage.Utility.Validation)
local SlotType = require(script.Parent.Parent.ReplicatedStorage.Types.SlotType)
-- Canonical player feedback (warnings). Leaf module — cycle-free.
local NotificationService = require(script.Parent.Base.NotificationService)

local SlotMenuService = {}

-- --- Injected service refs (wired by bootstrap) -------------------

local playerServiceRef: any = nil
local baseServiceRef: any = nil
local slotServiceRef: any = nil
local animalServiceRef: any = nil
local eggServiceRef: any = nil
local modifierServiceRef: any = nil
-- Phase 2.10: paid level upgrades (confirm endpoint only; the
-- menu-state cost preview below reads its pure calculation).
local upgradeServiceRef: any = nil
-- MAIN GAME: repaint hook for the stand's direct-upgrade
-- readout (`UpgradeButton.Level` / `UpgradeAmount`, owned by
-- StandDisplayService). Refreshed after every successful
-- upgrade confirm so the label tracks the new level + next
-- cost instantly (a PlayerState push follows anyway).
local standDisplayServiceRef: any = nil

function SlotMenuService.SetPlayerService(ps: any)
	playerServiceRef = ps
end

function SlotMenuService.SetBaseService(bs: any)
	baseServiceRef = bs
end

function SlotMenuService.SetSlotService(ss: any)
	slotServiceRef = ss
end

function SlotMenuService.SetAnimalService(svc: any)
	animalServiceRef = svc
end

function SlotMenuService.SetEggService(svc: any)
	eggServiceRef = svc
end

function SlotMenuService.SetModifierService(ms: any)
	modifierServiceRef = ms
end

function SlotMenuService.SetSellService(_ss: any)
	-- Compat shim: the menu owns Upgrade only (selling lives
	-- on the Sell prompt). Kept so bootstrap wiring is untouched.
end

function SlotMenuService.SetUpgradeService(us: any)
	upgradeServiceRef = us
end
function SlotMenuService.SetStandDisplayService(sds: any)
	standDisplayServiceRef = sds
end

-- Breadcrumb logger (Phase 2.9.2). Routed through the central
-- Debug module: the click -> request -> response -> frame chain
-- is provable in Studio output with ServerDebug on, silent
-- otherwise (no always-on prints).
local function _slog(...: any)
	local parts: { string } = {}
	for _, v in ipairs({ ... }) do
		parts[#parts + 1] = tostring(v)
	end
	Debug.Log('SlotMenu', table.concat(parts, ' '))
end

-- --- Constants -----------------------------------------------------

-- Shared snapshot/menu throttle: canonical in Systems.Security.
local REQUEST_THROTTLE_SECONDS = Security.RequestThrottleSeconds

local _lastRequest: { [number]: number } = {}
local _lastAction: { [number]: number } = {}

-- --- Guarded readers --------------------------------------------------

local function _moneyMultiplier(userId: number): number
	if modifierServiceRef and modifierServiceRef.GetMoneyMultiplier then
		local ok, v = pcall(modifierServiceRef.GetMoneyMultiplier, userId)
		if ok and type(v) == 'number' and v == v and v > 0 and v ~= math.huge then
			return v
		end
	end
	return 1
end

-- Compact float for $/sec generation (display only; currency
-- math stays in BigNumber strings everywhere else).
-- Canonical format: StandConfig (Rate decimals + missing token).
local function _fmtRate(v: number): string
	if type(v) ~= 'number' or v ~= v or v == math.huge or v == -math.huge or v < 0 then
		return StandConfig.Labels.RateMissing
	end
	if v == math.floor(v) then
		return tostring(v)
	end
	local s = string.format('%.' .. tostring(StandConfig.UpgradeReadout.RateDecimals) .. 'f', v)
	s = string.gsub(s, '0+$', '')
	s = string.gsub(s, '%.$', '')
	return s
end

-- Resolve + validate the slot for a requesting player. Returns
-- (slot, base) or (nil, code). Every endpoint calls this first:
-- unknown slot, foreign base, and empty slots all reject here,
-- before any object reads happen.
local function _resolveSlot(player: Player, slotId: any): (any?, any?, string?)
	if not Validation.LivePlayer(player) then
		return nil, nil, 'invalid-player'
	end
	if type(slotId) ~= 'string' or slotId == '' then
		return nil, nil, 'invalid-slot'
	end
	if not slotServiceRef or not baseServiceRef then
		return nil, nil, 'unavailable'
	end
	local ok, slot = pcall(slotServiceRef._findSlotById, slotId)
	if not ok or type(slot) ~= 'table' then
		return nil, nil, 'unknown-slot'
	end
	-- Arena stands are first-class slots: menus, upgrades,
	-- and sales resolve them exactly like normal slots. The
	-- ONLY arena content restriction is eggs (enforced at the
	-- egg placement boundary, never here).
	local okBase, base = pcall(baseServiceRef.GetBaseById, slot.baseId)
	if not okBase or type(base) ~= 'table' then
		return nil, nil, 'unknown-slot'
	end
	if base.ownerUserId ~= player.UserId then
		return nil, nil, 'not-owner'
	end
	return slot, base, nil
end

-- --- Menu snapshot ------------------------------------------------------

-- Authoritative preview for one owned slot. RemoteEvent-safe
-- (strings/numbers/booleans/plain tables only). { Valid = false }
-- when the slot holds nothing menuable (empty/reserved/unknown
-- occupant) — the client closes instead of rendering.
function SlotMenuService.BuildMenuState(player: Player, slotId: string): { [string]: any }
	local slot, _base, err = _resolveSlot(player, slotId)
	if not slot then
		return { Valid = false, SlotId = slotId, Error = err }
	end
	if slot.state ~= SlotType.State.Occupied or type(slot.occupantId) ~= 'string' then
		return { Valid = false, SlotId = slot.id }
	end
	local userId = player.UserId
	local occupantId: string = slot.occupantId

	if slot.occupantKind == SlotType.OccupantKind.Animal then
		if not animalServiceRef or not animalServiceRef.Get then
			return { Valid = false, SlotId = slot.id }
		end
		local okBr, animal = pcall(animalServiceRef.Get, occupantId)
		if not okBr or type(animal) ~= 'table' then
			return { Valid = false, SlotId = slot.id }
		end
		if animal.ownerUserId ~= userId then
			return { Valid = false, SlotId = slot.id, Error = 'not-owner' }
		end
		local definitionId = animal.definitionId
		if type(definitionId) ~= 'string' or definitionId == '' then
			return { Valid = false, SlotId = slot.id }
		end
		local okDef, rarity, def = pcall(AnimalConfig.Get, definitionId)
		if not okDef or type(rarity) ~= 'string' then
			return { Valid = false, SlotId = slot.id }
		end
		local displayName = animal.displayName
		if type(displayName) ~= 'string' or displayName == '' then
			if type(def) == 'table' and type(def.displayName) == 'string' then
				displayName = def.displayName
			else
				displayName = definitionId
			end
		end
		local level = animal.Level
		if type(level) ~= 'number' or level ~= math.floor(level) or level < 1 then
			level = 1
		end
		if level > LevelConfig.MaxLevel then
			level = LevelConfig.MaxLevel
		end
		-- Effective online generation through the canonical
		-- income path (base rate x player multiplier). Offline
		-- is irrelevant to this display.
		local menuTrait: string? = nil
		if type(animal.Trait) == 'string' and animal.Trait ~= '' then
			menuTrait = animal.Trait
		end
		local menuMutations: { string } = {}
		if type(animal.Mutations) == 'table' then
			for _, id in ipairs(animal.Mutations) do
				if type(id) == 'string' then
					menuMutations[#menuMutations + 1] = id
				end
			end
		end
		local like = { DefId = definitionId, Level = level, Trait = menuTrait, Mutations = menuMutations }
		local okRate, baseRate = pcall(AnimalStats.Calculate, like, 'Income')
		if not okRate or type(baseRate) ~= 'number' then
			baseRate = 0
		end
		local mult = _moneyMultiplier(userId)
		local effective = (baseRate :: number) * mult
		-- Pool from the persisted record (the collector's
		-- CashPool attribute mirrors this same value).
		local pool = '0'
		if playerServiceRef and playerServiceRef.GetPlayerData then
			local okData, data = pcall(playerServiceRef.GetPlayerData, userId)
			if okData and type(data) == 'table' and type(data.Brainrots) == 'table' then
				for _, rec in ipairs(data.Brainrots) do
					if type(rec) == 'table' and rec.Id == occupantId and rec.Type == 'Brainrot' then
						pool = BigNumber.sanitize(rec.CashPool) or '0'
						break
					end
				end
			end
		end
		-- Upgrade preview through the ONE authoritative cost
		-- calculation (never duplicated here). Below MaxLevel
		-- with a calculable cost the button offers the upgrade;
		-- at MaxLevel (or unknown definition) it shows the
		-- unavailable state. Affordability is NOT preview-gated
		-- (§32): the cost stays visible and the server rejects
		-- short funds at confirm time.
		local canUpgrade = false
		local upgradeCostRaw: string = StandConfig.Labels.RateMissing
		local upgradeButtonText: string = StandConfig.Labels.Unavailable
		if level < LevelConfig.MaxLevel and upgradeServiceRef and upgradeServiceRef.GetUpgradeCost then
			local okC, c = pcall(upgradeServiceRef.GetUpgradeCost, definitionId, level)
			if okC and type(c) == 'string' then
				upgradeCostRaw = c
				upgradeButtonText = StandConfig.Labels.UpgradeButton .. ' $' .. BigNumber.Format(c)
				canUpgrade = true
			end
		elseif level >= LevelConfig.MaxLevel then
			upgradeButtonText = StandConfig.Labels.MaxLevel
		end
		local newLevel: any = math.min(level + 1, LevelConfig.MaxLevel)
		if level >= LevelConfig.MaxLevel then
			newLevel = StandConfig.Labels.MaxLevelShort
		end
		return {
			Valid = true,
			SlotId = slot.id,
			Kind = 'animal',
			ObjectId = occupantId,
			Name = displayName,
			Rarity = rarity,
			Level = level,
			NewLevel = newLevel,
			CanUpgrade = canUpgrade,
			UpgradeCostRaw = upgradeCostRaw,
			UpgradeButtonText = upgradeButtonText,
			GenRaw = _fmtRate(effective),
			GenFormatted = '$' .. _fmtRate(effective) .. StandConfig.Labels.RateSuffix,
			PoolRaw = pool,
			PoolFormatted = '$' .. BigNumber.Format(pool),
		}
	elseif slot.occupantKind == SlotType.OccupantKind.Egg then
		if not eggServiceRef or not eggServiceRef.GetEgg then
			return { Valid = false, SlotId = slot.id }
		end
		local okBl, egg = pcall(eggServiceRef.GetEgg, occupantId)
		if not okBl or type(egg) ~= 'table' then
			return { Valid = false, SlotId = slot.id }
		end
		if egg.ownerUserId ~= userId then
			return { Valid = false, SlotId = slot.id, Error = 'not-owner' }
		end
		local rarity = egg.rarity
		if type(rarity) ~= 'string' or rarity == '' then
			return { Valid = false, SlotId = slot.id }
		end
		return {
			Valid = true,
			SlotId = slot.id,
			Kind = 'egg',
			ObjectId = occupantId,
			Name = StandConfig.Labels.EggName,
			Rarity = rarity,
			-- Eggs cannot be upgraded and carry no
			-- animal fields. Absent (nil) by construction —
			-- the client hides those rows instead of faking.
			-- Eggs are not sellable: no sell fields either.
			CanUpgrade = false,
		}
	end
	return { Valid = false, SlotId = slot.id }
end

-- --- Remote endpoints -----------------------------------------------------

local function _throttled(map: { [number]: number }, userId: number): boolean
	local now = os.clock()
	if map[userId] and now - map[userId] < REQUEST_THROTTLE_SECONDS then
		return true
	end
	map[userId] = now
	return false
end

local function _onMenuRequest(caller: Player, payload: any)
	if not caller or not caller.Parent then
		return
	end
	if _throttled(_lastRequest, caller.UserId) then
		return
	end
	local slotId = type(payload) == 'table' and payload.SlotId or nil
	local intent = type(payload) == 'table' and payload.Intent or nil
	if type(intent) ~= 'string' then
		intent = 'menu-state'
	end
	_slog('SERVER REQUEST player', caller.Name, 'slot', tostring(slotId), 'action', intent)
	local state = SlotMenuService.BuildMenuState(caller, slotId)
	_slog(
		'SERVER RESPONSE slot',
		tostring(slotId),
		'valid',
		tostring(state.Valid),
		'kind',
		tostring(state.Kind),
		'occupant',
		tostring(state.ObjectId)
	)
	Remotes.FireClient(caller, Remotes.Names.SlotMenuState, state)
end

-- Sale confirm (REMOVED): the slot menu owns Upgrade only.
-- Selling lives on the animal's Sell prompt (eggs are not
-- sellable). Any non-Upgrade confirm — including forged
-- sell confirms — is rejected here with no money moving and
-- no dispatch. The single sale path is the Sell prompt ->
-- SlotActionHandler 'SellAnimal' -> SellService.SellAnimal.
function SlotMenuService.HandleAction(caller: Player, payload: any): { [string]: any }
	local slotId = type(payload) == 'table' and payload.SlotId or nil
	local occupantId = type(payload) == 'table' and payload.OccupantId or nil
	local wantUpgrade = type(payload) == 'table' and payload.Action == 'Upgrade'
	if type(slotId) ~= 'string' or type(occupantId) ~= 'string' then
		return { SlotId = slotId, Success = false, Error = 'bad-request' }
	end
	local slot, _base, err = _resolveSlot(caller, slotId)
	if not slot then
		return { SlotId = slotId, Success = false, Error = err }
	end
	local kind: string? = nil
	if slot.state == SlotType.State.Occupied and slot.occupantId == occupantId then
		kind = slot.occupantKind
	end
	if kind ~= SlotType.OccupantKind.Animal and kind ~= SlotType.OccupantKind.Egg then
		-- Stale menu (moved/picked/sold/emptied since open):
		-- reject loudly, move no money. The client refreshes
		-- on any failure result.
		pcall(NotificationService.NotifyWarning, caller, 'Menu_StaleTarget')
		return { SlotId = slotId, Success = false, Error = 'stale' }
	end
	if not wantUpgrade then
		-- No sell confirms: the menu has no SellButton.
		pcall(NotificationService.NotifyWarning, caller, 'Menu_StaleTarget')
		return { SlotId = slotId, Success = false, Error = 'not-supported' }
	end
	if wantUpgrade then
		-- Upgrades are animal-only: an Egg context
		-- rejects before any money or level can move.
		if kind ~= SlotType.OccupantKind.Animal then
			pcall(NotificationService.NotifyWarning, caller, 'Menu_CannotUpgradeEgg')
			return { SlotId = slotId, Success = false, Error = 'not-animal' }
		end
		if not upgradeServiceRef or not upgradeServiceRef.UpgradeAnimal then
			pcall(NotificationService.NotifyWarning, caller, 'Menu_UpgradeUnavailable')
			return { SlotId = slotId, Success = false, Error = 'unavailable' }
		end
		local upOk, upResult = pcall(upgradeServiceRef.UpgradeAnimal, caller, occupantId)
		if not upOk or type(upResult) ~= 'table' or not upResult.success then
			-- No notify here: UpgradeService already reported
			-- the specific reason (insufficient/max-level/
			-- not-owner/invalid) through the same canonical
			-- path — a second toast would double-notify.
			return { SlotId = slotId, Success = false, Error = 'rejected' }
		end
		-- MAIN GAME: repaint the stand's direct-upgrade readout
		-- (new level -> next level + next cost) immediately.
		-- Display-only; the upgrade itself already settled in
		-- UpgradeService.
		if standDisplayServiceRef and standDisplayServiceRef.RefreshSlot then
			pcall(standDisplayServiceRef.RefreshSlot, slot)
		end
		return {
			SlotId = slotId,
			Success = true,
			NewLevel = upResult.newLevel,
			Cost = upResult.upgradeCost,
		}
	end
	-- Unreachable: non-Upgrade confirms return above.
	return { SlotId = slotId, Success = false, Error = 'not-supported' }
end

local function _onMenuAction(caller: Player, payload: any)
	if not caller or not caller.Parent then
		return
	end
	if _throttled(_lastAction, caller.UserId) then
		return
	end
	local result = SlotMenuService.HandleAction(caller, payload)
	-- UpgradeTrace: one-line receipt + verdict per upgrade
	-- press, so a client click can be followed end to end in
	-- output (existing _slog line below is preserved).
	local traceSlot = type(payload) == 'table' and payload.SlotId or nil
	local traceOcc = type(payload) == 'table' and payload.OccupantId or nil
	Debug.Log('UpgradeTrace', 
			tostring(traceSlot),
			tostring(traceOcc),
			caller.Name
		)
	if result.Success == true then
		Debug.Log('UpgradeTrace', 
				tostring(result.SlotId),
				tostring(traceOcc),
				tostring(result.NewLevel),
				tostring(result.Cost)
			)
	else
		Debug.Log('UpgradeTrace', 
				tostring(result.SlotId),
				tostring(traceOcc),
				tostring(result.Error)
			)
	end
	_slog(
		'SERVER ACTION player',
		caller.Name,
		'slot',
		tostring(result.SlotId),
		'action',
		tostring(type(payload) == 'table' and payload.Action or 'preview'),
		'success',
		tostring(result.Success),
		'error',
		tostring(result.Error)
	)
	Remotes.FireClient(caller, Remotes.Names.SlotMenuResult, result)
end

function SlotMenuService.Init()
	local ok, folderOrErr = pcall(Remotes.GetFolder)
	if not ok then
		Debug.Warn('SM', 'SlotMenuService.Init: Remotes folder not wired; menus unavailable', {})
		return
	end
	local folder = folderOrErr :: Folder
	local requestEvent = folder:FindFirstChild(Remotes.Names.SlotMenuRequest)
	if requestEvent and requestEvent:IsA('RemoteEvent') then
		(requestEvent :: RemoteEvent).OnServerEvent:Connect(_onMenuRequest)
	else
		Debug.Warn('SM', 'SlotMenuService.Init: SlotMenuRequest remote missing', {})
	end
	local actionEvent = folder:FindFirstChild(Remotes.Names.SlotMenuAction)
	if actionEvent and actionEvent:IsA('RemoteEvent') then
		(actionEvent :: RemoteEvent).OnServerEvent:Connect(_onMenuAction)
	else
		Debug.Warn('SM', 'SlotMenuService.Init: SlotMenuAction remote missing', {})
	end
end

function SlotMenuService.ForgetPlayer(userId: number)
	_lastRequest[userId] = nil
	_lastAction[userId] = nil
end

return table.freeze(SlotMenuService)
