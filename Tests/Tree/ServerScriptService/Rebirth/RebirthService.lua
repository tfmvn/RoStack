--!strict
--!native
--[[
	Rebirth.RebirthService
	======================
	Server-authoritative Rebirth progression. Owns ONLY the Rebirth
	transaction; every domain stays authoritative in its own
	service (money/EconomyService shape, animals/AnimalService,
	base/BaseService+SlotService, arena/ArenaProgressionService,
	multiplier/ModifierService, profile/PlayerService).

	Flow: client fires RebirthAction {Action='Rebirth'} (or
	{Action='State'} for a snapshot). The server resolves
	current->next SEQUENTIALLY (client numbers are never trusted),
	validates money (BigNumber.Compare), arena level
	(ArenaProgressionService.GetArenaLevel), and owned Animals
	(DefId + Trait + MinimumLevel, AND-semantics, one record per
	requirement, duplicates need distinct animals) from the
	authoritative profile inventory — then executes the configured
	reset under a per-player mutex, in dependency order:

	  animals (runtime destroy + slot release + profile removal)
	  -> base (release + fresh assign)
	  -> arena (ResetArena)
	  -> money (= StartingCash) + rebirth number + multiplier
	  -> PushState + RebirthState + RebirthResult

	Refusals (fail-closed, zero mutation): carrying/stealing
	(CarryRegistry), raid-locked owned animals (raid covers the
	whole run, so an active raid always blocks), busy mutex,
	unconfigured next, any unmet requirement.

	Reset(Base=true) = ReleasePlayerBase + AssignBaseForPlayer +
	PlayerService.AssignBase (fresh stands/slots; same flow as
	join). No stand/base-upgrade persistence exists in the
	project, so stands+slots+animals ARE the full base state.
	LuckyBlocks (eggs), GearAutoBuy, and profile Multipliers-compat
	are intentionally untouched. Persistence rides the normal
	ProfileService release cycle (no explicit save API exists).
]]

local Players = game:GetService('Players')

local Validation = require(game:GetService('ReplicatedStorage').Utility.Validation)
local Remotes = require(game:GetService('ReplicatedStorage').Utility.Remotes)
local Debug = require(game:GetService('ReplicatedStorage').Utility.Debug)
local BigNumber = require(game:GetService('ReplicatedStorage').Utility.BigNumber)
local RebirthConfig = require(game:GetService('ReplicatedStorage').Config.Economy.Rebirth)
local RebirthUnlocks = require(game:GetService('ReplicatedStorage').Utility.RebirthUnlocks)
local AnimalConfig = require(game:GetService('ReplicatedStorage').Config.Creatures.Animals)

local PlayerService = require(script.Parent.Parent.PlayerService)
local AnimalService = require(script.Parent.Parent.AnimalService)
local BaseService = require(script.Parent.Parent.BaseService)
local SlotService = require(script.Parent.Parent.Base.SlotService)
local ArenaProgressionService = require(script.Parent.Parent.Arena.ArenaProgressionService)
local ModifierService = require(script.Parent.Parent.ModifierService)
local CarryRegistry = require(script.Parent.Parent.Carry.CarryRegistry)
local ArenaService = require(script.Parent.Parent.Arena.ArenaService)
-- Steal rollback before teardown (recover-then-sweep, mirroring
-- owner-leave): the thief-side carry and victim-side rows must
-- be resolved BEFORE runtime objects are destroyed. Cycle-safe:
-- nothing in StealService's subtree requires RebirthService.
local StealService = require(script.Parent.Parent.Steal.StealService)
local EggService = require(script.Parent.Parent.EggService)
local SlotType = require(game:GetService('ReplicatedStorage').Types.SlotType)
-- Funnel analytics (leaf module — never gameplay-critical).
local FunnelService = require(script.Parent.Parent.FunnelService)
-- Player monitoring (Discord embeds + registry; leaf module,
-- never gameplay-critical).
local PlayerLogger = require(script.Parent.Parent.PlayerLogger.PlayerLogger)

local RebirthService = {}

local REBIRTH_MODIFIER_SOURCE = 'Rebirth'

local _wired = false
local _busy: { [number]: boolean } = {}

-- --- Reads --------------------------------------------------------

-- Current completed Rebirth count (0 = none). Fail-closed to 0.
function RebirthService.GetRebirth(userId: number): number
	local rebirth = 0
	pcall(function()
		local data = PlayerService.GetPlayerData(userId)
		if
			type(data) == 'table'
			and type(data.Rebirth) == 'number'
			and data.Rebirth == math.floor(data.Rebirth)
			and data.Rebirth >= 0
		then
			rebirth = data.Rebirth
		end
	end)
	return rebirth
end

-- Pending rebirth override for stand construction: the base
-- rebuild below must use the NEW value (profile still holds the
-- old one until commit). Set immediately before the rebuild,
-- cleared right after (and on every abort path below) so normal
-- joins/assigns always read the profile.
local _pendingBuild: { [number]: number } = {}

function RebirthService.BeginRebirthBuild(userId: number, nextIndex: number)
	if type(userId) == 'number' and type(nextIndex) == 'number' then
		_pendingBuild[userId] = nextIndex
	end
end

function RebirthService.EndRebirthBuild(userId: number)
	if type(userId) == 'number' then
		_pendingBuild[userId] = nil
	end
end

-- Resolver consumed by DynamicSlotService (injected at boot):
-- pending override wins, else the profile value.
function RebirthService.ResolveRebirthForStands(userId: number): number
	if type(userId) == 'number' and _pendingBuild[userId] ~= nil then
		return _pendingBuild[userId] :: number
	end
	return RebirthService.GetRebirth(userId)
end

-- Re-apply the persisted multiplier to the session authority.
-- ModifierService is in-memory per session (cleared on leave),
-- so every join must restore it. Idempotent (same triple
-- identity replaces itself).
function RebirthService.ApplySessionModifiers(userId: number)
	local current = RebirthService.GetRebirth(userId)
	if current > 0 then
		local entry = RebirthConfig.Get(current)
		if entry == nil then
			entry = RebirthConfig.Get(RebirthConfig.MaxConfigured())
		end
		if entry ~= nil then
			pcall(function()
				ModifierService.AddModifier(
					userId,
					REBIRTH_MODIFIER_SOURCE,
					ModifierService.ModifierType.MoneyMultiplier,
					entry.Rewards.MoneyMultiplier
				)
			end)
			Debug.Log(
				'Rebirth',
				'session modifiers applied',
				{ userId = tostring(userId), rebirth = tostring(current) }
			)
		end
	end
	-- Base label initializes on every join (1.0x at Rebirth 0).
	RebirthService.RefreshBaseMultiplier(userId)
end

-- Display-only formatting: 1 -> "1", 2 -> "2", 2.5 ->
-- "2.5", never float garbage. Gameplay math never reads this
-- string.
local function formatMultiplier(value: any): string
	local n = tonumber(value) or 1
	if n ~= n or n == math.huge or n == -math.huge or n <= 0 then
		n = 1
	end
	if n == math.floor(n) then
		return tostring(n)
	end
	local s = ('%.2f'):format(n)
	s = string.gsub(s, '0+$', '')
	s = string.gsub(s, '%.$', '')
	return s
end

-- Resolve the MoneyMultPart label for a base folder. Shared by
-- refresh + hide so both agree on the Studio hierarchy:
--   Base/MoneyMultPart/SurfaceGui/TextLabel
-- (direct children preferred, recursive fallbacks). Returns
-- the TextLabel or nil. Never throws.
local function _multLabel(folder: any): TextLabel?
	local label: TextLabel? = nil
	pcall(function()
		if typeof(folder) ~= 'Instance' then
			return
		end
		local part = (folder :: Instance):FindFirstChild('MoneyMultPart')
			or (folder :: Instance):FindFirstChild('MoneyMultPart', true)
		if part == nil then
			return
		end
		local surface = (part :: Instance):FindFirstChild('SurfaceGui')
			or (part :: Instance):FindFirstChildWhichIsA('SurfaceGui', true)
		if surface == nil then
			return
		end
		local node = (surface :: Instance):FindFirstChild('TextLabel')
		if node ~= nil and node:IsA('TextLabel') then
			label = node
		end
	end)
	return label
end

-- Write the owner's CURRENT authoritative money multiplier
-- (ModifierService.GetMoneyMultiplier — the exact value income
-- uses) onto their own Base's MoneyMultPart label, and show
-- it. Display only; never read back. Missing nodes warn
-- once-ish and skip (the Studio asset may vary); other
-- players' bases untouched. No base (unowned) = nothing to
-- show; use HideBaseMultiplier to conceal a released base.
function RebirthService.RefreshBaseMultiplier(userId: number)
	if type(userId) ~= 'number' then
		return
	end
	local mult = 1
	pcall(function()
		mult = ModifierService.GetMoneyMultiplier(userId)
	end)
	local text = 'Mult: ' .. formatMultiplier(mult) .. 'x'
	pcall(function()
		local base = BaseService.GetBaseByOwner(userId)
		local folder = if type(base) == 'table' then base.folder else nil
		local label = _multLabel(folder)
		if label ~= nil then
			label.Text = text
			label.Visible = true
		end
	end)
	Debug.Log('Rebirth', 'base multiplier display', { userId = tostring(userId), text = text })
end

-- Conceal a Base's multiplier label (release/leave path).
-- Owner-gated like refresh: resolves through the
-- authoritative BaseService ownership (never proximity).
-- Must be called while the owner still holds the base;
-- HideAllBaseMultipliers covers boot (no owners yet).
-- Missing nodes skip silently. Never throws.
function RebirthService.HideBaseMultiplier(userId: number)
	if type(userId) ~= 'number' then
		return
	end
	pcall(function()
		local base = BaseService.GetBaseByOwner(userId)
		local folder = if type(base) == 'table' then base.folder else nil
		local label = _multLabel(folder)
		if label ~= nil then
			label.Visible = false
		end
	end)
	Debug.Log('Rebirth', 'base multiplier hidden', { userId = tostring(userId) })
end

-- Conceal EVERY Base's multiplier label (server start: all
-- bases unowned, so all labels hide). Never throws.
function RebirthService.HideAllBaseMultipliers()
	pcall(function()
		local all: any = nil
		pcall(function()
			all = BaseService.GetAllBases()
		end)
		if type(all) ~= 'table' then
			return
		end
		for _, base in pairs(all) do
			if type(base) == 'table' then
				local label = _multLabel((base :: any).folder)
				if label ~= nil then
					pcall(function()
						(label :: TextLabel).Visible = false
					end)
				end
			end
		end
	end)
end

local function traitOf(value: any): string
	if type(value) == 'string' and value ~= '' then
		return value
	end
	return 'Normal'
end

-- Match requirements against owned profile records (authoritative
-- inventory: Data.Brainrots). AND-semantics with consumption:
-- each requirement claims ONE distinct record. Returns rows with
-- per-requirement progress for the GUI + overall pass/fail.
local function matchAnimals(records: { any }, rules: { any }): ({ { [string]: any } }, boolean)
	local pool: { any } = {}
	for _, rec in ipairs(records) do
		if type(rec) == 'table' and rec.Type == 'Brainrot' then
			pool[#pool + 1] = rec
		end
	end
	local rows: { { [string]: any } } = {}
	local allMatched = true
	for _, rule in ipairs(rules) do
		local wantDef = rule.DefId
		local wantTrait = traitOf(rule.Trait)
		local wantLevel = rule.MinimumLevel
		local bestLevel: number? = nil
		local bestId: string? = nil
		for _, rec in ipairs(pool) do
			if rec.DefId == wantDef and traitOf(rec.Trait) == wantTrait then
				local level = tonumber(rec.Level) or 0
				if bestLevel == nil or level > bestLevel then
					bestLevel = level
					bestId = rec.Id
				end
			end
		end
		local matched = bestLevel ~= nil and (bestLevel :: number) >= wantLevel and bestId ~= nil
		if matched then
			-- Consume: remove the claimed record from the pool so
			-- one animal can never satisfy two requirements.
			for i, rec in ipairs(pool) do
				if rec.Id == bestId then
					table.remove(pool, i)
					break
				end
			end
		else
			allMatched = false
		end
		-- Preview source for the card viewport is attached by the
		-- caller (template clone, not the owned live model — see
		-- attachTemplateModels). Kept nil here by construction.
		local displayName: string? = nil
		pcall(function()
			local _, def = AnimalConfig.Get(wantDef)
			if type(def) == 'table' and type(def.displayName) == 'string' then
				displayName = def.displayName
			end
		end)
		rows[#rows + 1] = {
			DefId = wantDef,
			DisplayName = displayName or wantDef,
			Trait = wantTrait,
			MinimumLevel = wantLevel,
			Matched = matched == true,
			BestLevel = bestLevel,
			TemplateModel = nil,
		}
	end
	return rows, allMatched
end

-- Replicated template-preview store: clients cannot read
-- ServerStorage, so requirement visuals ship as clones parked in
-- ReplicatedStorage.RebirthPreviews/U<userId>/ (same keepsake
-- pattern as ArenaResultModels). Per-rule cache: existing clones
-- are reused across state rebuilds, stale keys pruned. Bounded
-- by requirement count; destroyed on ForgetPlayer.
local function previewFolder(userId: number): Folder?
	local root: Instance? = nil
	pcall(function()
		root = game:GetService('ReplicatedStorage'):FindFirstChild('RebirthPreviews')
		if root == nil then
			local created = Instance.new('Folder')
			created.Name = 'RebirthPreviews'
			created.Parent = game:GetService('ReplicatedStorage')
			root = created
		end
	end)
	if root == nil then
		return nil
	end
	local folder: Instance? = nil
	pcall(function()
		folder = (root :: Instance):FindFirstChild('U' .. tostring(userId))
		if folder == nil then
			local created = Instance.new('Folder')
			created.Name = 'U' .. tostring(userId)
			created.Parent = root
			folder = created
		end
	end)
	if folder == nil or not (folder :: Instance):IsA('Folder') then
		return nil
	end
	return folder :: Folder
end

local function attachTemplateModels(userId: number, rows: { { [string]: any } })
	local folder = previewFolder(userId)
	if folder == nil then
		return
	end
	local wanted: { [string]: boolean } = {}
	for _, row in ipairs(rows) do
		if type(row) ~= 'table' then
			continue
		end
		local wantDef = row.DefId
		local wantTrait = if type(row.Trait) == 'string' then row.Trait else 'Normal'
		local key = tostring(wantDef) .. '|' .. tostring(wantTrait)
		wanted[key] = true
		local existing = folder:FindFirstChild(key)
		-- Rarity rides the row for the client's outline color
		-- (canonical RarityConfig identity, same as HUD).
		local rarity: string? = nil
		pcall(function()
			rarity = AnimalConfig.Get(wantDef)
		end)
		if type(rarity) == 'string' then
			row.Rarity = rarity
		end
		if existing ~= nil and existing:IsA('Model') then
			row.TemplateModel = existing
		elseif type(rarity) == 'string' then
			local template: Model? = nil
			pcall(function()
				template = AnimalService.GetTemplate(rarity, wantDef, if wantTrait ~= 'Normal' then wantTrait else nil)
			end)
			if template ~= nil then
				local parked: Model? = nil
				pcall(function()
					local fresh = (template :: Model):Clone()
					fresh.Name = key
					fresh.Parent = folder
					parked = fresh
				end)
				if parked ~= nil then
					row.TemplateModel = parked
					Debug.Log('Rebirth', 'template preview parked', {
						userId = tostring(userId),
						defId = tostring(wantDef),
						trait = tostring(wantTrait),
					})
				end
			end
			if row.TemplateModel == nil then
				Debug.Warn('RebirthViewport', 'failed to resolve template (card renders text-only)', {
					userId = tostring(userId),
					defId = tostring(wantDef),
					trait = tostring(wantTrait),
				})
			end
		end
	end
	-- Prune clones for rules no longer present. `__`-prefixed
	-- keys belong to the unlock previews below (attachUnlockModels)
	-- and are never touched here.
	pcall(function()
		for _, child in ipairs((folder :: Folder):GetChildren()) do
			if child:IsA('Model') and wanted[child.Name] ~= true and string.sub(child.Name, 1, 2) ~= '__' then
				child:Destroy()
			end
		end
	end)
end

-- Unlock preview store (same keepsake pattern as the animal
-- requirement previews above): the client cannot read
-- ServerStorage, so the stand templates behind an unlock are
-- parked as clones in ReplicatedStorage.RebirthPreviews/U<userId>/
-- under stable `__` keys. Gear unlocks need NO parked model — the
-- client resolves them from the existing canonical
-- ReplicatedStorage.GearShopPreviews (published by
-- GearShopService) by GearId.
local UNLOCK_STAND_KEY = '__Stand'
local UNLOCK_ARENA_KEY = '__ArenaStand'

-- The SAME template source DynamicSlotService builds runtime
-- stands from (never a second model). Lazy-required: resolution
-- failures (headless specs, missing assets) park nothing and the
-- affected card renders text-only.
local function resolveStandTemplate(wantArena: boolean): Instance?
	local template: Instance? = nil
	pcall(function()
		local DynamicSlotService = require(script.Parent.Parent.Base.DynamicSlotService)
		if wantArena then
			template = DynamicSlotService.GetArenaTemplate()
		else
			template = DynamicSlotService.GetTemplate()
		end
	end)
	if
		typeof(template) == 'Instance'
		and ((template :: Instance):IsA('Model') or (template :: Instance):IsA('BasePart'))
	then
		return template
	end
	return nil
end

local function attachUnlockModels(userId: number, unlocks: { { [string]: any } })
	if type(unlocks) ~= 'table' or #unlocks == 0 then
		return
	end
	local needStand = false
	local needArena = false
	for _, entry in ipairs(unlocks) do
		if type(entry) == 'table' then
			if entry.Kind == RebirthUnlocks.Kind.AnimalStand then
				needStand = true
			elseif entry.Kind == RebirthUnlocks.Kind.ArenaStand then
				needArena = true
			end
			-- Display name rides the row from the single
			-- presentation source (RebirthUnlocks.DisplayName:
			-- fixed stand labels, canonical GearConfig names).
			if type(entry.Name) ~= 'string' then
				local name: string? = nil
				pcall(function()
					name = RebirthUnlocks.DisplayName(entry)
				end)
				entry.Name = name or '?'
			end
		end
	end
	if not needStand and not needArena then
		-- Gear-only (or empty) preview: no stand models needed,
		-- but a previous preview may have parked stale `__` keys.
		pcall(function()
			local root = game:GetService('ReplicatedStorage'):FindFirstChild('RebirthPreviews')
			local folder = root and root:FindFirstChild('U' .. tostring(userId)) or nil
			if folder ~= nil then
				for _, key in ipairs({ UNLOCK_STAND_KEY, UNLOCK_ARENA_KEY }) do
					local stale = folder:FindFirstChild(key)
					if stale ~= nil then
						stale:Destroy()
					end
				end
			end
		end)
		return
	end
	local folder = previewFolder(userId)
	if folder == nil then
		return
	end
	local function park(key: string, wantArena: boolean): Instance?
		local existing = folder:FindFirstChild(key)
		if existing ~= nil and existing:IsA('Model') then
			return existing
		end
		if existing ~= nil and existing:IsA('BasePart') then
			return existing
		end
		local template = resolveStandTemplate(wantArena)
		if template == nil then
			Debug.Warn('RebirthUnlock', 'failed to resolve stand template (card renders text-only)', {
				userId = tostring(userId),
				key = key,
			})
			return nil
		end
		local parked: Instance? = nil
		pcall(function()
			local fresh = (template :: Instance):Clone()
			fresh.Name = key
			fresh.Parent = folder
			parked = fresh
		end)
		if parked ~= nil then
			Debug.Log('Rebirth', 'unlock preview parked', {
				userId = tostring(userId),
				key = key,
			})
		end
		return parked
	end
	local standModel: Instance? = nil
	local arenaModel: Instance? = nil
	if needStand then
		standModel = park(UNLOCK_STAND_KEY, false)
	else
		pcall(function()
			local stale = folder:FindFirstChild(UNLOCK_STAND_KEY)
			if stale ~= nil then
				stale:Destroy()
			end
		end)
	end
	if needArena then
		arenaModel = park(UNLOCK_ARENA_KEY, true)
	else
		pcall(function()
			local stale = folder:FindFirstChild(UNLOCK_ARENA_KEY)
			if stale ~= nil then
				stale:Destroy()
			end
		end)
	end
	for _, entry in ipairs(unlocks) do
		if type(entry) == 'table' then
			if entry.Kind == RebirthUnlocks.Kind.AnimalStand and standModel ~= nil then
				entry.TemplateModel = standModel
			elseif entry.Kind == RebirthUnlocks.Kind.ArenaStand and arenaModel ~= nil then
				entry.TemplateModel = arenaModel
			end
		end
	end
end

local function checkRaidLock(userId: number): boolean
	local locked = false
	pcall(function()
		for _, snapshot in ipairs(AnimalService.ListForPlayer(userId)) do
			if type(snapshot) == 'table' and type(snapshot.UniqueId) == 'string' then
				local ok, isLocked = pcall(ArenaService.IsAnimalRaidLocked, snapshot.UniqueId)
				if ok and isLocked == true then
					locked = true
					break
				end
			end
		end
	end)
	return locked
end

-- --- State snapshot (GUI source of truth) --------------------------

function RebirthService.BuildState(userId: number): { [string]: any }
	local current = RebirthService.GetRebirth(userId)
	local nextIndex = current + 1
	local entry = RebirthConfig.Get(nextIndex)
	local state: { [string]: any } = {
		Current = current,
		Next = if entry ~= nil then nextIndex else nil,
		Maxed = entry == nil,
		CanRebirth = false,
	}
	if entry == nil then
		return state
	end
	local money = '0'
	local arenaLevel = 1
	local records: { any } = {}
	pcall(function()
		local data = PlayerService.GetPlayerData(userId)
		if type(data) == 'table' then
			if type(data.Money) == 'string' then
				money = data.Money
			end
			if type(data.Brainrots) == 'table' then
				records = data.Brainrots
			end
		end
	end)
	pcall(function()
		arenaLevel = ArenaProgressionService.GetArenaLevel(userId)
	end)
	local moneyOk = false
	pcall(function()
		local cmp = BigNumber.Compare(money, entry.Requirements.Money)
		moneyOk = cmp ~= nil and (cmp :: number) >= 0
	end)
	local arenaOk = arenaLevel >= entry.Requirements.ArenaLevel
	local rows, animalsOk = matchAnimals(records, entry.Requirements.Animals)
	attachTemplateModels(userId, rows)
	-- Unlock preview rows: WHAT this Rebirth grants, derived from
	-- the same authoritative configs the gameplay uses
	-- (RebirthConfig stand counts + GearConfig.RequiredRebirth).
	-- Stand rows carry the parked template clone; gear rows carry
	-- the GearId the client resolves via GearShopPreviews.
	local unlocks = RebirthUnlocks.BuildForPreview(current, nextIndex)
	attachUnlockModels(userId, unlocks)
	state.Money = money
	state.MoneyRequired = entry.Requirements.Money
	state.MoneySatisfied = moneyOk
	state.ArenaLevel = arenaLevel
	state.ArenaRequired = entry.Requirements.ArenaLevel
	state.ArenaSatisfied = arenaOk
	state.Animals = rows
	state.Unlocks = unlocks
	state.StartingCash = entry.Rewards.StartingCash
	state.MoneyMultiplier = entry.Rewards.MoneyMultiplier
	state.CanRebirth = moneyOk and arenaOk and animalsOk
	return state
end

local function pushState(player: Player, userId: number)
	local state = RebirthService.BuildState(userId)
	pcall(Remotes.FireClient, player, Remotes.Names.RebirthState, state)
end

-- --- Transaction ---------------------------------------------------

local function fail(code: string): { [string]: any }
	return { success = false, error = code }
end

-- Development-time post-rebirth validation (§30). After a
-- successful rebirth the runtime must be functionally
-- identical to a fresh join:
--   1. valid current Base, owned by the player;
--   2. PlayerService base binding agrees;
--   3. stands/slots exist;
--   4. CarryRegistry clean (no yield may interleave a grab
--      between the entry gate and teardown — a violation here
--      proves one exists);
--   5. no live steal involving the player (thief or victim);
--   6. every persisted egg record resolves to a slot.
-- Failures log loudly but never block success (display +
-- diagnostics must not brick the transaction they observe).
function RebirthService.ValidatePostRebirth(userId: number)
	pcall(function()
		local failed = 0
		local function bad(reason: string, context: any?)
			failed += 1
			warn(('[RebirthLifecycle] POST-REBIRTH VALIDATION FAILED %s'):format(reason))
			Debug.Warn('RebirthLifecycle', 'post-rebirth validation failed', {
				userId = tostring(userId),
				reason = reason,
				context = tostring(context),
			})
		end
		local base: any = nil
		pcall(function()
			base = BaseService.GetBaseByOwner(userId)
		end)
		if type(base) ~= 'table' then
			bad('no-base', nil)
		else
			if base.ownerUserId ~= userId then
				bad('base-owner-mismatch', tostring(base.ownerUserId))
			end
			local slotCount = 0
			pcall(function()
				if type(base.slots) == 'table' then
					for _ in pairs(base.slots) do
						slotCount += 1
					end
				end
			end)
			if slotCount < 1 then
				bad('no-stands', tostring(slotCount))
			end
			local boundId: string? = nil
			pcall(function()
				boundId = PlayerService.GetBaseId(userId)
			end)
			if boundId ~= base.id then
				bad('base-binding-mismatch', tostring(boundId))
			end
		end
		local carrying = false
		pcall(function()
			carrying = CarryRegistry.IsCarrying(userId) == true
		end)
		if carrying then
			bad('carry-not-clean', nil)
		end
		pcall(function()
			CarryRegistry.ForEach(function(uid: number, item: any)
				if type(item) == 'table' and type(item.steal) == 'table' then
					local originalOwner: any = (item.steal :: any).originalOwnerUserId
					if uid == userId or originalOwner == userId then
						bad('steal-still-active', tostring(uid))
					end
				end
			end)
		end)
		pcall(function()
			local data = PlayerService.GetPlayerData(userId)
			if type(data) == 'table' and type(data.LuckyBlocks) == 'table' then
				for _, rec in ipairs(data.LuckyBlocks) do
					if type(rec) == 'table' and type(rec.SlotId) == 'string' then
						local slot: any = nil
						pcall(function()
							slot = SlotService._findSlotById(rec.SlotId)
						end)
						if slot == nil then
							bad('egg-record-unresolved', tostring(rec.SlotId))
						end
					end
				end
			end
		end)
		Debug.Log('RebirthLifecycle', 'post-rebirth validation done', {
			userId = tostring(userId),
			failed = tostring(failed),
		})
	end)
end

function RebirthService.RequestRebirth(player: Player): { [string]: any }
	if not Validation.LivePlayer(player) then
		return fail('invalid-player')
	end
	local userId = player.UserId
	if _busy[userId] then
		return fail('busy')
	end
	_busy[userId] = true
	local function release()
		_busy[userId] = nil
	end

	local current = RebirthService.GetRebirth(userId)
	-- First-ever signal from existing persistent state (no new
	-- persistence): the profile rebirth count is 0 only when
	-- this player has never rebirthed. Captured pre-commit;
	-- the success hook below uses it to keep FirstRebirth
	-- honest across sessions.
	local wasFirstEver = current == 0
	local nextIndex = current + 1
	local entry = RebirthConfig.Get(nextIndex)
	if entry == nil then
		release()
		return fail('maxed')
	end
		Debug.Log('Rebirth', ('request player=%s current=%d next=%d'):format(player.Name, current, nextIndex))
	-- Funnel: rebirth requested (scoped per target number so
	-- repeated failing attempts do not spam).
	pcall(function()
		FunnelService:LogStep(player, 'Rebirth', 'RebirthAttempted', {
			rebirth_number = nextIndex,
			_key = tostring(nextIndex),
		})
	end)

	-- Runtime safety (fail-closed, zero mutation): carrying /
	-- stealing players and active raiders cannot reset mid-state.
	local carrying = false
	pcall(function()
		carrying = CarryRegistry.IsCarrying(userId)
	end)
	if carrying then
		release()
		return fail('carrying')
	end
	if checkRaidLock(userId) then
		release()
		return fail('raid-locked')
	end

	-- Validate EVERYTHING from authoritative state.
	local data: any = nil
	pcall(function()
		data = PlayerService.GetPlayerData(userId)
	end)
	if type(data) ~= 'table' then
		release()
		return fail('no-profile')
	end
	local money: string = if type(data.Money) == 'string' then data.Money else '0'
	local moneyOk = false
	pcall(function()
		local cmp = BigNumber.Compare(money, entry.Requirements.Money)
		moneyOk = cmp ~= nil and (cmp :: number) >= 0
	end)
		Debug.Log('Rebirth', ('requirement money current=%s required=%s'):format(
			tostring(money),
			tostring(entry.Requirements.Money)
		))
	if not moneyOk then
		release()
		return fail('money')
	end
	local arenaLevel = 1
	pcall(function()
		arenaLevel = ArenaProgressionService.GetArenaLevel(userId)
	end)
		Debug.Log('Rebirth', ('requirement arena current=%d required=%d'):format(arenaLevel, entry.Requirements.ArenaLevel))
	if arenaLevel < entry.Requirements.ArenaLevel then
		release()
		return fail('arena')
	end
	local records: { any } = if type(data.Brainrots) == 'table' then data.Brainrots else {}
	local rows, animalsOk = matchAnimals(records, entry.Requirements.Animals)
	attachTemplateModels(userId, rows)
	for _, row in ipairs(rows) do
				Debug.Log('Rebirth', ('requirement animal defId=%s trait=%s level=%s best=%s matched=%s'):format(
				tostring(row.DefId),
				tostring(row.Trait),
				tostring(row.MinimumLevel),
				tostring(row.BestLevel),
				tostring(row.Matched)
			))
	end
	if not animalsOk then
		release()
		return fail('animals')
	end
		Debug.Log('Rebirth', ('validation passed player=%s next=%d'):format(player.Name, nextIndex))
	-- Funnel: requirements met (money + arena + animals validated).
	pcall(function()
		FunnelService:LogStep(player, 'Rebirth', 'RebirthRequirementReached', {
			rebirth_number = nextIndex,
			_key = tostring(nextIndex),
		})
	end)

	-- Commit (dependency order: steal rollback, then BASE
	-- re-init, then animals, arena, money, rebirth count +
	-- multiplier). Every step is pcall-guarded and the profile
	-- is the single source of truth — a failed step logs
	-- loudly and aborts with 'reset-failed' instead of claiming
	-- success. The base step runs BEFORE any destructive reset
	-- so a failure leaves animals/money intact and the retry
	-- revalidates cleanly; completed prefix steps are
	-- idempotent on retry because each targets
	-- already-consumed state).
	local reset = entry.Reset
	-- Recover-then-sweep (mirrors owner-leave): resolve any
	-- live steal involving this player BEFORE destroying
	-- runtime state — as thief (their carry) AND as victim
	-- (their animals/eggs carried by someone else). Without
	-- this, the wipe below destroys objects out from under
	-- live carries: the thief keeps a dangling destSlot
	-- reservation + speed snapshot, and victim rows strand.
	-- The entry carrying-gate above already guarantees THIS
	-- player isn't carrying; this covers the victim side and
	-- any thief-side residue.
	Debug.Log('RebirthLifecycle', 'clearing carry/steal state', { player = player.Name })
	pcall(function()
		StealService.RollbackIfStealing(userId, 'rebirth')
		for _, rec in ipairs(data.Brainrots) do
			if type(rec) == 'table' and type(rec.Id) == 'string' then
				StealService.RollbackStolenTarget(SlotType.OccupantKind.Animal, rec.Id, 'rebirth')
			end
		end
		for _, rec in ipairs(data.LuckyBlocks) do
			if type(rec) == 'table' and type(rec.Id) == 'string' then
				StealService.RollbackStolenTarget(SlotType.OccupantKind.Egg, rec.Id, 'rebirth')
			end
		end
	end)
	-- Base FIRST, animals second. A failed base re-init must
	-- leave animals/money/profile untouched so the attempt
	-- fails clean (retry revalidates fine); wiping animals
	-- before securing the new base strands the player
	-- baseless AND animalless with no working retry (the
	-- animal validation can never pass again). The wipe loop
	-- below is order-safe: ReleaseBase already force-released
	-- runtimes (settling + removing their rows exactly once),
	-- and per-id Destroy/Remove calls are verified no-ops on
	-- already-gone ids, so survivors (rows without a runtime)
	-- are still settled + removed and the end state matches
	-- the old order exactly.
	if reset.Base then
				Debug.Log('Rebirth', ('resetting base player=%s'):format(player.Name))
		Debug.Log('RebirthLifecycle', 'releasing base', { player = player.Name })
		local okBase = false
		-- The rebuild below must construct the NEW rebirth's
		-- stand counts (the profile still holds the old value
		-- until commit) — pending override, cleared on every
		-- exit of this block.
		RebirthService.BeginRebirthBuild(userId, nextIndex)
		pcall(function()
			-- Prefer the player's CURRENT base: release, then
			-- re-acquire the SAME id (Available now, atomically
			-- — no other assign can interleave), so rebirth
			-- never migrates the player to a different base.
			-- A player with NO base (retrying a previous
			-- reset-failed) skips release and assigns
			-- directly, so the retry can still succeed.
			local prevBase: any = nil
			pcall(function()
				prevBase = BaseService.GetBaseByOwner(userId)
			end)
			local prevBaseId: string? = if type(prevBase) == 'table' then prevBase.id else nil
			local released = prevBaseId == nil
			if not released then
				released = BaseService.ReleasePlayerBase(userId) == true
			end
			if released then
				Debug.Log('RebirthLifecycle', 'assigning new base', { player = player.Name })
				local base: any = nil
				if type(prevBaseId) == 'string' then
					pcall(function()
						base = BaseService.AssignBaseById(userId, prevBaseId :: string)
					end)
				end
				if base == nil then
					pcall(function()
						base = BaseService.AssignBaseForPlayer(userId)
					end)
				end
				if base ~= nil and type(base.id) == 'string' then
					if PlayerService.AssignBase(userId, base.id) then
						-- Spawn ownership follows the (possibly
						-- new) base: re-point RespawnLocation so
						-- the next death respawns at the current
						-- base, never the released one.
						if BaseService.PointPlayerToBaseSpawn(player, base) then
							-- Refuse to commit a stand-less base:
							-- a 0-slot rebuild is a content/setup
							-- failure (missing template/markers),
							-- never a valid rebirth target.
							local standCount = 0
							pcall(function()
								standCount = #(base.slots or {})
							end)
							if standCount > 0 then
								okBase = true
							else
								Debug.Warn('Rebirth', 'rebuilt base has no stands; aborting', {
									userId = tostring(userId),
								})
							end
						end
					end
				end
			end
		end)
		RebirthService.EndRebirthBuild(userId)
		if not okBase then
			Debug.Warn(
				'Rebirth',
				'base reset failed; aborting before destructive remainder',
				{ userId = tostring(userId) }
			)
			release()
			return fail('reset-failed')
		end
		Debug.Log('RebirthLifecycle', 'rebuilding slots', { player = player.Name })
	end
	if reset.Animals then
				Debug.Log('Rebirth', ('resetting animals player=%s'):format(player.Name))
		local ids: { string } = {}
		pcall(function()
			for _, rec in ipairs(data.Brainrots) do
				if type(rec) == 'table' and type(rec.Id) == 'string' then
					ids[#ids + 1] = rec.Id
				end
			end
		end)
		for _, id in ipairs(ids) do
			pcall(function()
				local slot: any = nil
				pcall(function()
					slot = SlotService.FindSlotByOccupant(id)
				end)
				AnimalService.DestroyRuntimeAnimal(id)
				if type(slot) == 'table' and type(slot.id) == 'string' then
					pcall(SlotService.ReleaseSlot, slot.id)
				end
				PlayerService.RemoveAnimal(userId, id)
			end)
		end
		data.Brainrots = {}
	end
	if reset.ArenaLevel then
				Debug.Log('Rebirth', ('resetting arena player=%s'):format(player.Name))
		pcall(ArenaProgressionService.ResetArena, userId)
	end
	if reset.Money then
				Debug.Log('Rebirth', ('applying starting cash=%s'):format(tostring(entry.Rewards.StartingCash)))
		data.Money = BigNumber.sanitize(entry.Rewards.StartingCash) or '0'
	end
	data.Rebirth = nextIndex
		Debug.Log('Rebirth', ('applying multiplier=%s'):format(tostring(entry.Rewards.MoneyMultiplier)))
	pcall(function()
		ModifierService.AddModifier(
			userId,
			REBIRTH_MODIFIER_SOURCE,
			ModifierService.ModifierType.MoneyMultiplier,
			entry.Rewards.MoneyMultiplier
		)
	end)
	-- Live base label: the new multiplier shows immediately, no
	-- reconnect or GUI reopen required. Display-only: wrapped so
	-- a missing label part can never throw past release() and
	-- permanently wedge this player's rebirth mutex.
	pcall(RebirthService.RefreshBaseMultiplier, userId)
	-- Join-equivalence repair (§40): re-home stale persisted
	-- egg SlotIds, rebuild models destroyed with the old
	-- stands, reinstall their prompts. Without this, pre-
	-- rebirth eggs keep aliasing fresh slots/records and
	-- interact with clean rejections or dead slots — the
	-- exact surface the post-rebirth bug reports describe.
	-- Never throws (internal pcall); safe no-op when nothing
	-- is stale.
	pcall(EggService.ReconcileAfterBaseSwap, userId)

	-- Replicate authoritative state: fresh base snapshot (new
	-- stands/slots), HUD money/rebirth via the canonical push,
	-- then the GUI snapshot + the result.
	local snap: any = nil
	pcall(function()
		snap = BaseService.Snapshot(userId)
	end)
	pcall(PlayerService.PushState, player, snap)
	pcall(pushState, player, userId)
	pcall(Remotes.FireClient, player, Remotes.Names.RebirthResult, {
		Success = true,
		Rebirth = nextIndex,
	})
	RebirthService.ValidatePostRebirth(userId)
	Debug.Log('RebirthLifecycle', 'complete', { player = player.Name, rebirth = tostring(nextIndex) })
	release()
		Debug.Log('Rebirth', ('success player=%s rebirth=%d'):format(player.Name, nextIndex))
	-- Funnel: rebirth committed above (reset + rewards applied).
	-- FirstRebirth fires only when the pre-commit profile count
	-- was 0 (true first-ever); later rebirths log only the
	-- scoped RebirthSucceeded.
	pcall(function()
		local meta = { rebirth_number = nextIndex, _key = tostring(nextIndex) }
		FunnelService:LogStep(player, 'Rebirth', 'RebirthSucceeded', meta)
		if wasFirstEver then
			FunnelService:LogStep(player, 'Progression', 'FirstRebirth', nil)
		end
		-- Player monitoring: committed rebirth (same point).
		pcall(PlayerLogger.LogMilestone, player, 'RebirthSucceeded', { rebirth = nextIndex })
	end)
	-- Leaderboards: rebirth resets money (moves the GLOBAL
	-- money-only score) and IS the primary TAB key — expedite
	-- both refreshes (periodic loops pick it up regardless).
	-- Lazy requires: neither service takes server authorities
	-- at load, so this is cycle-free. Never throws, never
	-- yields — safe inside the release path.
	pcall(function()
		require(script.Parent.Parent.Leaderboard.LeaderboardService).MarkDirty(userId)
	end)
	pcall(function()
		require(script.Parent.Parent.TabList.TabListService).MarkDirty()
	end)
	return { success = true, rebirth = nextIndex }
end

function RebirthService.Init()
	if _wired then
		return
	end
	_wired = true
	pcall(function()
		local folder = Remotes.GetFolder()
		local event = folder:WaitForChild(Remotes.Names.RebirthAction, 10)
		if event ~= nil and (event :: Instance):IsA('RemoteEvent') then
			(event :: RemoteEvent).OnServerEvent:Connect(function(player: Player, payload: any)
				local action = if type(payload) == 'table' then payload.Action else nil
				if action == 'State' then
					if Validation.LivePlayer(player) then
						pushState(player, player.UserId)
					end
					return
				end
				-- Default (including empty/missing payloads):
				-- attempt the next sequential rebirth. The client
				-- never selects a number.
				local result = RebirthService.RequestRebirth(player)
				if result.success ~= true then
					pcall(Remotes.FireClient, player, Remotes.Names.RebirthResult, {
						Success = false,
						Error = result.error,
					})
					-- Failed attempts still refresh the GUI state
					-- (progress may have changed since it opened).
					if Validation.LivePlayer(player) then
						pushState(player, player.UserId)
					end
				end
			end)
		else
			Debug.Warn('Rebirth', 'RebirthAction remote missing; rebirths disabled', {})
		end
	end)
end

function RebirthService._TestReset()
	_busy = {}
end

-- Leave cleanup: drop the in-flight flag and destroy this
-- player's parked template previews (bounded, per-requirement).
-- Never touches live animals, profile, or other players.
function RebirthService.ForgetPlayer(userId: number)
	if type(userId) ~= 'number' then
		return
	end
	_busy[userId] = nil
	_pendingBuild[userId] = nil
	pcall(function()
		local root = game:GetService('ReplicatedStorage'):FindFirstChild('RebirthPreviews')
		if root ~= nil then
			local folder = root:FindFirstChild('U' .. tostring(userId))
			if folder ~= nil then
				folder:Destroy()
			end
		end
	end)
end

return table.freeze(RebirthService)
