--!strict
--!native
--[[
	SellService
	============
	The ONE authority for selling Animals. Server-authoritative
	end to end: the client may request "sell animal ID" (Sell
	prompt on the animal) but never a price; every value is
	resolved here from authoritative state. Eggs are NOT
	sellable — there is no egg sale path anywhere.

	Two halves, both owned here so gameplay and the debug HUD
	can never disagree (§38/§39 — one formula, many readers):

	  * Pure calculations (no service refs, BigNumber-safe):
	      GetAnimalBaseSellValue(defId)      -> base $ string
	      GetAnimalLevelSellValue(defId, lv, trait?, muts?)
	          -> base x level x trait-sell x mutation-sell
	      GetAnimalTotalPayout(defId, lv, pool, trait?, muts?)
	    Animal formula: LevelAdjusted = BaseSellValue x Level
	    (AnimalConfig.SellBaseValue, per rarity).

  	  * Transaction (server only — reached from the Sell
  	    prompt via SlotActionHandler 'SellAnimal'; no remote
  	    ever calls it directly):
	      SellAnimal(player, animalId)
	    Returns { success, error?, payout?, ... } and grants
	    through EconomyService with { ApplyMultiplier = false }:
	    the Money multiplier is for online passive income ONLY
	    and never shapes a sale (§21).

	Animal payout atomicity (§5-§7):
	  1. validate everything (owner, def, level, slot, state)
	  2. IncomeService.ConsumePoolForSale zeroes the pool under
	     the slot's claim lock — a racing collection either wins
	     first (sale consumes '0') or loses (collect sees '0'):
	     the pool pays EXACTLY ONCE
	  3. single AddMoney(saleValue + pool); on failure the pool
	     is restored onto the still-live record and the animal
	     is untouched (safe rollback, §6)
	  4. teardown: runtime destroy, slot release, profile removal
	     (the removal settlement sees a zero pool — no-op), cash
	     sync, push, notify. Income landing between grant and
	     removal settles normally, so nothing is ever lost.

	Carried objects are REJECTED (§18, second option): the carried
	model carries no prompts by architecture (grab wipes them),
	so a carried sale is unreachable via prompt; the service
	rejects it cleanly and CarryRegistry can never dangle.

	No yields anywhere in the critical sections — each sale is
	atomic w.r.t. every other server thread. Double-sell collapses
	to ONE success: the winner removes the registry record and the
	loser reads 'not-found'.
]]

local AnimalConfig = require(script.Parent.Parent.ReplicatedStorage.Config.Creatures.Animals)
local LevelConfig = require(script.Parent.Parent.ReplicatedStorage.Config.Creatures.Progression)
local BigNumber = require(script.Parent.Parent.ReplicatedStorage.Utility.BigNumber)
local Validation = require(script.Parent.Parent.ReplicatedStorage.Utility.Validation)
local Debug = require(script.Parent.Parent.ReplicatedStorage.Utility.Debug)
local TransactionReason = require(script.Parent.Parent.ReplicatedStorage.Types.TransactionReason)
local TraitConfig = require(script.Parent.Parent.ReplicatedStorage.Config.Creatures.Traits)
local MutationConfig = require(script.Parent.Parent.ReplicatedStorage.Config.Creatures.Mutations)
local CarryPrompts = require(script.Parent.Animal.CarryPrompts)
local NotificationService = require(script.Parent.Base.NotificationService)
-- Sell prompt dispatch needs the unified handler at load;
-- the handler resolves SellService back lazily at call time
-- (see SlotActionHandler header), so this stays cycle-free.
local SlotActionHandler = require(script.Parent.Action.SlotActionHandler)
local Remotes = require(script.Parent.Parent.ReplicatedStorage.Utility.Remotes)
-- Canonical generation/income math for the confirmation
-- preview (same AnimalStats path the menu + overhead use).
local AnimalStats = require(script.Parent.Parent.ReplicatedStorage.Utility.AnimalStats)
-- Raid lock: animals locked into an active Arena raid cannot
-- be sold mid-run (the raid fights on its immutable
-- snapshot; selling underneath it would corrupt ownership).
-- ArenaService is require-safe here (ReplicatedStorage deps
-- only — no cycle back into SellService).
local ArenaService = require(script.Parent.Arena.ArenaService)

local SellService = {}

-- --- Stable error codes -------------------------------------------

SellService.Error = {
	InvalidPlayer = 'invalid-player',
	InvalidId = 'invalid-id',
	NotFound = 'not-found',
	NotOwner = 'not-owner',
	Busy = 'busy',
	Carried = 'carried',
	InvalidState = 'invalid-state',
	InvalidDefinition = 'invalid-definition',
	InvalidLevel = 'invalid-level',
	InvalidRarity = 'invalid-rarity',
	NoSellValue = 'no-sell-value',
	SlotState = 'slot-state',
	PoolBusy = 'pool-busy',
	GrantFailed = 'grant-failed',
	ServiceUnavailable = 'service-unavailable',
}

-- --- Injected service refs (wired by bootstrap) -------------------

local playerServiceRef: any = nil
local slotServiceRef: any = nil
local baseServiceRef: any = nil
local animalServiceRef: any = nil
local economyServiceRef: any = nil
local incomeServiceRef: any = nil
local modifierServiceRef: any = nil
function SellService.SetPlayerService(ps: any)
	playerServiceRef = ps
end

function SellService.SetSlotService(ss: any)
	slotServiceRef = ss
end

function SellService.SetBaseService(bs: any)
	baseServiceRef = bs
end

function SellService.SetAnimalService(svc: any)
	animalServiceRef = svc
end

function SellService.SetEggService(_svc: any)
	-- Compat shim: eggs are not sellable, so the egg service
	-- is no longer read. Kept so bootstrap wiring is untouched.
end

function SellService.SetEconomyService(es: any)
	economyServiceRef = es
end

function SellService.SetIncomeService(ins: any)
	incomeServiceRef = ins
end

function SellService.SetModifierService(ms: any)
	modifierServiceRef = ms
end

-- Compact float for $/sec generation (display only; currency
-- math stays in BigNumber strings everywhere else). Mirrors
-- SlotMenuService's canonical rate display.
local function _fmtRate(v: number): string
	if type(v) ~= 'number' or v ~= v or v == math.huge or v == -math.huge or v < 0 then
		return 'N/A'
	end
	if v == math.floor(v) then
		return tostring(v)
	end
	local s = string.format('%.2f', v)
	s = string.gsub(s, '0+$', '')
	s = string.gsub(s, '%.$', '')
	return s
end

local function _moneyMultiplier(userId: number): number
	if modifierServiceRef and modifierServiceRef.GetMoneyMultiplier then
		local ok, v = pcall(modifierServiceRef.GetMoneyMultiplier, userId)
		if ok and type(v) == 'number' and v == v and v > 0 and v ~= math.huge then
			return v
		end
	end
	return 1
end

-- Display-safe level: authoritative record Level clamped
-- into 1..MaxLevel, '?' when unusable (same convention as
-- the animal overhead, the only level display).
local function _displayLevel(animal: any): string
	local level = animal and (animal :: any).Level
	if type(level) ~= 'number' or level ~= level or level == math.huge then
		return '?'
	end
	local n = math.floor(level)
	if n < 1 or n > LevelConfig.MaxLevel then
		return '?'
	end
	return 'Lv. ' .. tostring(n)
end

-- Wire the Sell prompt dispatch (native ProximityPrompt.
-- Triggered source) and the confirmation remote. The prompt
-- NEVER sells: it opens the SellConfirmation GUI via
-- PreviewSell (read-only validation + preview push). Only
-- the GUI's Sell button (SellConfirmAction) can transact,
-- through the unified SlotActionHandler so prompt sales
-- share ALL validation with the single pipeline. Init is
-- idempotent (bootstrap + specs may both call it).
local _wiredCallbacks = false

function SellService.Init()
	if _wiredCallbacks then
		return
	end
	_wiredCallbacks = true
	CarryPrompts.SetSellPromptCallback(function(player: Player, animalId: string)
		return SellService.PreviewSell(player, animalId)
	end)
	pcall(function()
		local folder = Remotes.GetFolder()
		local actionEvent = folder:WaitForChild(Remotes.Names.SellConfirmAction, 10)
		if actionEvent ~= nil and (actionEvent :: Instance):IsA('RemoteEvent') then
			(actionEvent :: RemoteEvent).OnServerEvent:Connect(function(player: Player, payload: any)
				local id = type(payload) == 'table' and payload.AnimalId or nil
				if type(id) ~= 'string' or id == '' then
					return
				end
				SellService.ConfirmSell(player, id)
			end)
		else
			Debug.Warn('SL', 'SellService.Init: SellConfirmAction remote missing', {})
		end
	end)
end

-- --- Pure calculations (no refs — shared by gameplay + HUD) --------

local function _validLevel(level: any): boolean
	return type(level) == 'number' and level == math.floor(level) and level >= 1 and level <= LevelConfig.MaxLevel
end

-- Base sell value for an animal definition, as a canonical
-- BigNumber string. Nil when the definition or its rarity's
-- sell base is unknown — callers fail the sale, never guess.
function SellService.GetAnimalBaseSellValue(definitionId: string): string?
	if type(definitionId) ~= 'string' or definitionId == '' then
		return nil
	end
	local ok, rarity = pcall(AnimalConfig.Get, definitionId)
	if not ok or type(rarity) ~= 'string' then
		return nil
	end
	local base = AnimalConfig.SellBaseValue[rarity]
	if type(base) ~= 'number' or base ~= base or base ~= math.floor(base) or base <= 0 or base == math.huge then
		return nil
	end
	return BigNumber.sanitize(tostring(base))
end

-- Level-adjusted sell value: base x level x rarity-sell x
-- trait-sell x mutation-sell, BigNumber-exact throughout
-- (level is a small bounded integer; all multipliers are
-- terminating decimals folded by MultiplyDecimal). The
-- rarity factor (Animals.SellMultiplier, 0.75 uniform) is the
-- liquidation haircut: a Level-1 animal sells for 75% of egg
-- cost, so hatch-and-sell can never print money (per-egg EV
-- simulates at 70-85% — see the balance report). Optional
-- trait/mutations default to 1x, so pre-2.11 callers are
-- byte-identical apart from the rarity factor.
function SellService.GetAnimalLevelSellValue(
	definitionId: string,
	level: number,
	trait: string?,
	mutations: { string }?
): string?
	if not _validLevel(level) then
		return nil
	end
	local base = SellService.GetAnimalBaseSellValue(definitionId)
	if not base then
		return nil
	end
	local ok, scaled = pcall(BigNumber.Multiply, base, level)
	if not ok or type(scaled) ~= 'string' then
		return nil
	end
	local rarity: string? = nil
	pcall(function()
		-- Animals.Get returns (rarity, def): first value is
		-- the rarity string.
		rarity = AnimalConfig.Get(definitionId)
	end)
	local sellFactor = '1'
	pcall(function()
		local row = type(rarity) == 'string' and AnimalConfig.SellMultiplier[rarity] or nil
		if type(row) == 'string' then
			sellFactor = row
		end
	end)
	local okF, factored = pcall(BigNumber.MultiplyDecimal, scaled, sellFactor)
	if not okF or type(factored) ~= 'string' then
		return nil
	end
	local okT, withTrait = pcall(BigNumber.MultiplyDecimal, factored, TraitConfig.SellMultiplierFor(trait))
	if not okT or type(withTrait) ~= 'string' then
		return nil
	end
	local mutMult = MutationConfig.SellFold(mutations)
	local okM, shaped = pcall(BigNumber.MultiplyDecimal, withTrait, mutMult)
	if not okM or type(shaped) ~= 'string' then
		return nil
	end
	return shaped
end

-- Total animal payout: level-adjusted value + current pool.
-- Pool travels as a canonical BigNumber string, never a number.
function SellService.GetAnimalTotalPayout(
	definitionId: string,
	level: number,
	pool: string,
	trait: string?,
	mutations: { string }?
): string?
	local levelValue = SellService.GetAnimalLevelSellValue(definitionId, level, trait, mutations)
	local cleanPool = BigNumber.sanitize(pool) or '0'
	if not levelValue then
		return nil
	end
	local ok, total = pcall(BigNumber.Add, levelValue, cleanPool)
	if not ok or type(total) ~= 'string' then
		return nil
	end
	return total
end

-- --- Internal helpers -------------------------------------------------

local function _fail(code: string): { [string]: any }
	Debug.Log('SL', 'sale rejected', { error = code })
	return { success = false, error = code }
end

local function _wired(): boolean
	return playerServiceRef ~= nil
		and slotServiceRef ~= nil
		and baseServiceRef ~= nil
		and animalServiceRef ~= nil
		and economyServiceRef ~= nil
		and incomeServiceRef ~= nil
end

-- Push fresh state after a successful sale. Best-effort reads
-- (snapshot may be nil if the base is gone); PushState tolerates
-- a nil snapshot the same way every other service path does.
-- Success toasts go through NotificationService at the call
-- sites (post-commit, with server-calculated payout data).
local function _pushState(player: Player)
	local userId = player.UserId
	if playerServiceRef and baseServiceRef then
		local snap
		if baseServiceRef.Snapshot then
			local ok, s = pcall(baseServiceRef.Snapshot, userId)
			if ok then
				snap = s
			end
		end
		playerServiceRef.PushState(player, snap)
	end
end

-- --- Animal sale ------------------------------------------------------

-- Sell one owned Animal: (base x level) + CashPool, atomically.
-- See the module header for the exact ordering guarantees.
function SellService.SellAnimal(player: Player, animalId: string): { [string]: any }
	if not Validation.LivePlayer(player) then
		return _fail(SellService.Error.InvalidPlayer)
	end
	if type(animalId) ~= 'string' or animalId == '' then
		return _fail(SellService.Error.InvalidId)
	end
	if not _wired() then
		return _fail(SellService.Error.ServiceUnavailable)
	end
	local userId = player.UserId

	local animal = animalServiceRef.Get(animalId)
	if not animal then
		return _fail(SellService.Error.NotFound)
	end
	if animal.ownerUserId ~= userId then
		return _fail(SellService.Error.NotOwner)
	end
	if animal._mutex then
		return _fail(SellService.Error.Busy)
	end
	animal._mutex = true

	local function abort(code: string): { [string]: any }
		animal._mutex = false
		return _fail(code)
	end

	-- Carried objects cannot be sold (their model carries no
	-- prompts by architecture; the registry stays consistent
	-- because we never touch it here).
	if animal.state == 'Carried' then
		return abort(SellService.Error.Carried)
	end
	-- Arena raid lock: an animal fighting in an active raid
	-- is temporarily unsellable. The raid snapshot stays
	-- valid; the sale simply waits until the raid ends.
	if ArenaService.IsAnimalRaidLocked(animalId) then
		return abort(SellService.Error.Busy)
	end
	if animal.state == 'Consumed' or animal.state == 'Destroyed' then
		return abort(SellService.Error.InvalidState)
	end
	if type(animal.slotId) ~= 'string' then
		return abort(SellService.Error.SlotState)
	end
	local definitionId = animal.definitionId
	if type(definitionId) ~= 'string' or definitionId == '' then
		return abort(SellService.Error.InvalidDefinition)
	end
	local rarity, _def = AnimalConfig.Get(definitionId)
	if not rarity then
		return abort(SellService.Error.InvalidDefinition)
	end
	local level = animal.Level
	if not _validLevel(level) then
		return abort(SellService.Error.InvalidLevel)
	end
	-- The animal must sit on a live Occupied slot owned by
	-- the seller (rejects mid-walk Reserved, released, and
	-- cross-base states alike). Normal and arena stands sell
	-- through this exact path.
	local slot = slotServiceRef.FindSlotByOccupant(animalId)
	if not slot or slot.state ~= 'Occupied' or slot.occupantId ~= animalId or slot.ownerUserId ~= userId then
		return abort(SellService.Error.SlotState)
	end
	-- Phase 2.11: trait + mutations shape the value (exact
	-- decimals). Runtime record is authoritative; the profile row
	-- is the fallback (same object either way).
	local animalTrait = animal.Trait
	local animalMutations = animal.Mutations
	local saleValue = SellService.GetAnimalLevelSellValue(definitionId, level, animalTrait, animalMutations)
	if not saleValue then
		return abort(SellService.Error.NoSellValue)
	end

	-- Consume the pool under the slot's claim lock: a racing
	-- collection takes the pool (we consume '0') or loses the
	-- claim (it then reads '0'). Exactly once, either way.
	local pool, poolErr = incomeServiceRef.ConsumePoolForSale(userId, animalId)
	if not pool then
		if poolErr == 'busy' then
			return abort(SellService.Error.PoolBusy)
		end
		return abort(SellService.Error.SlotState)
	end
	local total = SellService.GetAnimalTotalPayout(definitionId, level, pool, animalTrait, animalMutations)
	if not total then
		return abort(SellService.Error.NoSellValue)
	end

	-- Single grant, explicitly unshaped: the multiplier is for
	-- online passive income, never for sales.
	local result = economyServiceRef.AddMoney(userId, total, TransactionReason.SellAnimal, { ApplyMultiplier = false })
	if not result or not result.Success then
		-- Rollback: the record is still live (nothing removed
		-- yet), so the consumed pool goes back. Income landing
		-- in the gap settles on the next removal as usual.
		local data = playerServiceRef.GetPlayerData(userId)
		if data and type(data.Brainrots) == 'table' then
			for _, rec in ipairs(data.Brainrots) do
				if type(rec) == 'table' and rec.Id == animalId then
					local current = BigNumber.sanitize(rec.CashPool) or '0'
					local restoredOk, restored = pcall(BigNumber.Add, current, pool)
					if restoredOk and type(restored) == 'string' then
						rec.CashPool = restored
					else
						rec.CashPool = pool
					end
					break
				end
			end
		end
		Debug.Warn('SL', 'SellAnimal: grant failed; pool restored, animal intact', {
			userId = tostring(userId),
			animalId = tostring(animalId),
			code = tostring(result and result.Code),
		})
		return abort(SellService.Error.GrantFailed)
	end

	-- Teardown (grant already succeeded; every step is infallible
	-- instance/service cleanup — see header for ordering notes).
	animalServiceRef.DestroyRuntimeAnimal(animalId)
	if slotServiceRef.ReleaseSlot then
		if not slotServiceRef.ReleaseSlot(slot.id) then
			Debug.Warn('SL', 'SellAnimal: ReleaseSlot failed post-grant', {
				userId = tostring(userId),
				slotId = tostring(slot.id),
			})
		end
	end
	CarryPrompts._UnregisterPromptsForSlot(slot.id)
	-- Profile removal runs the pool settlement hook, which sees
	-- the zeroed pool and no-ops — the consumed pool was already
	-- paid inside `total` above and can never pay again.
	if playerServiceRef.RemoveAnimal then
		playerServiceRef.RemoveAnimal(userId, animalId)
	end
	-- Codes: the freed slot may unblock queued code rewards
	-- (eggs/animals waiting for space). Best-effort delivery
	-- through the owning service; never fails the sale.
	pcall(function()
		local CodesService = require(script.Parent.Codes.CodesService)
		CodesService.TryDeliverPending(userId)
	end)
	-- Authoritative HUD trigger: the canonical money-sync wire
	-- (CashCollected { Amount, NewMoney } -> MoneyPoolController
	-- burst + target), fired ONLY here on success — never on
	-- validation failure, never twice (the sale commits once).
	-- The payout below MUST be the raw BigNumber decimal string
	-- (never a formatted '$25K': sanitize would fail and the
	-- animation would render '+$0').
	local saleNewMoney: string? = nil
	if type(result.NewMoney) == 'string' then
		saleNewMoney = result.NewMoney
	end
	pcall(function()
		Remotes.FireClient(player, Remotes.Names.CashCollected, {
			Amount = total,
			NewMoney = saleNewMoney,
		})
	end)
	_pushState(player)
	-- Success ONLY after the sale commit above (grant + teardown).
	pcall(
		NotificationService.NotifySuccess,
		player,
		'Sell_Success',
		{ Name = animal.displayName or 'Animal', Amount = total, Rarity = rarity }
	)
	Debug.Log('SL', 'SellAnimal ok', {
		userId = tostring(userId),
		animalId = tostring(animalId),
		payout = total,
	})
	return { success = true, payout = total, saleValue = saleValue, pool = pool }
end

-- --- Sell confirmation (two-step sale) -------------------------------
--
-- The Sell prompt NEVER sells directly: it opens the
-- StarterGui.Main.SellConfirmation GUI via a preview push,
-- and only the GUI's Sell button (SellConfirmAction) can
-- transact — through the canonical SellAnimal pipeline
-- below, which revalidates everything. Preview validation
-- is strictly read-only: it never sets _mutex, never moves
-- money, never mutates the animal.

local function _invalidPreview(animalId: any, reason: string): { [string]: any }
	return { Valid = false, AnimalId = animalId, Reason = reason }
end

-- Read-only sellability check shared by the preview. Returns
-- { ok, animal, slot, reason }. No mutex, no mutation.
local function _checkSellable(player: Player, animalId: any): { [string]: any }
	if not Validation.LivePlayer(player) then
		return { ok = false, reason = 'invalid-player' }
	end
	if type(animalId) ~= 'string' or animalId == '' then
		return { ok = false, reason = 'invalid-id' }
	end
	if not _wired() then
		return { ok = false, reason = 'service-unavailable' }
	end
	local userId = player.UserId
	local animal: any = nil
	pcall(function()
		animal = animalServiceRef.Get(animalId)
	end)
	if type(animal) ~= 'table' then
		return { ok = false, reason = 'not-found' }
	end
	if animal.ownerUserId ~= userId then
		return { ok = false, reason = 'not-owner' }
	end
	if animal._mutex then
		return { ok = false, reason = 'busy' }
	end
	if animal.state ~= 'Slotted' then
		return { ok = false, reason = 'invalid-state' }
	end
	if type(animal.slotId) ~= 'string' then
		return { ok = false, reason = 'slot-state' }
	end
	local definitionId = animal.definitionId
	if type(definitionId) ~= 'string' or definitionId == '' then
		return { ok = false, reason = 'invalid-definition' }
	end
	local rarity: string? = nil
	pcall(function()
		rarity = AnimalConfig.Get(definitionId)
	end)
	if type(rarity) ~= 'string' then
		return { ok = false, reason = 'invalid-definition' }
	end
	local level = animal.Level
	if not _validLevel(level) then
		return { ok = false, reason = 'invalid-level' }
	end
	local slot: any = nil
	pcall(function()
		slot = slotServiceRef.FindSlotByOccupant(animalId)
	end)
	if
		type(slot) ~= 'table'
		or slot.state ~= 'Occupied'
		or slot.occupantId ~= animalId
		or slot.ownerUserId ~= userId
	then
		return { ok = false, reason = 'slot-state' }
	end
	if ArenaService.IsAnimalRaidLocked(animalId) then
		return { ok = false, reason = 'busy' }
	end
	return { ok = true, animal = animal, slot = slot, rarity = rarity }
end

-- Validate a sell-preview request and push the confirmation
-- data to the client. Read-only: money, XP, mutex, records,
-- and slots are untouched. Returns the pushed state table
-- (Valid = false opens nothing client-side).
--
-- Visual model: the payload carries the LIVE animal model as
-- an Instance reference (replicated Workspace object, so the
-- client resolves it with the event). The client Clone()s it
-- locally into the viewport and strips prompts/scripts — the
-- live model is never reparented, moved, or mutated. No
-- ServerStorage access from the client, no Workspace scans,
-- no parallel asset system.
function SellService.PreviewSell(player: Player, animalId: string): { [string]: any }
	local checked = _checkSellable(player, animalId)
	if not checked.ok then
		return _invalidPreview(animalId, checked.reason)
	end
	local animal = checked.animal
	local userId = player.UserId
	-- Canonical display data (same sources the overhead and
	-- menu previews use — never client-supplied).
	local displayName = animal.displayName
	if type(displayName) ~= 'string' or displayName == '' then
		displayName = tostring(animal.definitionId)
	end
	local trait: string? = nil
	if type(animal.Trait) == 'string' and animal.Trait ~= '' then
		trait = animal.Trait
	end
	local mutations: { string } = {}
	if type(animal.Mutations) == 'table' then
		for _, id in ipairs(animal.Mutations) do
			if type(id) == 'string' and id ~= '' then
				mutations[#mutations + 1] = id
			end
		end
	end
	table.sort(mutations)
	local generationText = 'N/A'
	do
		local like = {
			DefId = animal.definitionId,
			Level = animal.Level,
			Trait = trait,
			Mutations = mutations,
		}
		local okRate, baseRate = pcall(AnimalStats.Calculate, like, 'Income')
		if okRate and type(baseRate) == 'number' then
			generationText = '$' .. _fmtRate(baseRate * _moneyMultiplier(userId)) .. '/sec'
		end
	end
	-- Display-only sale total through the ONE authoritative
	-- payout calculation (pool included, same as the real
	-- transaction below). The final sale recomputes it;
	-- the client never controls it.
	local sellValueRaw: string? = nil
	do
		local pool = '0'
		if playerServiceRef and playerServiceRef.GetPlayerData then
			local okData, data = pcall(playerServiceRef.GetPlayerData, userId)
			if okData and type(data) == 'table' and type(data.Brainrots) == 'table' then
				for _, rec in ipairs(data.Brainrots) do
					if type(rec) == 'table' and rec.Id == animalId and rec.Type == 'Brainrot' then
						pool = BigNumber.sanitize(rec.CashPool) or '0'
						break
					end
				end
			end
		end
		local okPay, total =
			pcall(SellService.GetAnimalTotalPayout, animal.definitionId, animal.Level, pool, trait, mutations)
		if okPay and type(total) == 'string' then
			sellValueRaw = total
		end
	end
	-- The preview's single source of truth: the ACTUAL model
	-- currently sitting in the animal's stand (never a template,
	-- never a reconstruction). A missing model is an ERROR, never
	-- a silent fallback — the client leaves the viewport empty.
	local liveModel: Instance? = nil
	if typeof(animal.model) == 'Instance' and (animal.model :: Instance):IsA('Model') then
		liveModel = animal.model
	end
	-- TEMPORARY DEBUG (remove after trace): prove the exact source
	-- instance the preview ships to the client (stand model vs
	-- template vs wrong animal). Parent = the stand container.
	if liveModel ~= nil then
		local full, parentFull = 'unknown', 'unknown'
		local parts, mesh, decals, surfaceAppear, guis = 0, 0, 0, 0, 0
		local guiNames: { string } = {}
		pcall(function()
			full = (liveModel :: Instance):GetFullName()
			local p = (liveModel :: Instance).Parent
			if p ~= nil then
				parentFull = p:GetFullName()
			end
			for _, desc in ipairs((liveModel :: Model):GetDescendants()) do
				if desc:IsA('BasePart') then
					parts += 1
					if desc:IsA('MeshPart') then
						mesh += 1
					end
				elseif desc:IsA('Decal') or desc:IsA('Texture') then
					decals += 1
				elseif desc:IsA('SurfaceAppearance') then
					surfaceAppear += 1
				elseif desc:IsA('BillboardGui') or desc:IsA('SurfaceGui') then
					guis += 1
					if #guiNames < 12 then
						guiNames[#guiNames + 1] = desc.ClassName .. ':' .. desc.Name
					end
				end
			end
		end)
		Debug.Log('Sell', ('[SellViewport DEBUG] SERVER SOURCE slot=%s animal=%s stand=%s Name=%s FullName=%s parent=%s parts=%d meshParts=%d decals/textures=%d surfaceAppearances=%d guis=%d[%s]'):format(
				tostring(animal.slotId),
				tostring(animalId),
				tostring(animal.slotId),
				(liveModel :: Instance).Name,
				full,
				parentFull,
				parts,
				mesh,
				decals,
				surfaceAppear,
				guis,
				table.concat(guiNames, ',')
			)
		)
	else
		Debug.Log('Sell', ('[SellViewport DEBUG] SERVER SOURCE slot=%s animal=%s stand=%s MISSING (client viewport will stay empty)'):format(
				tostring(animal.slotId),
				tostring(animalId),
				tostring(animal.slotId)
			)
		)
	end
	if liveModel == nil then
		Debug.Warn('SellConfirmViewport', 'ERROR: actual stand model not found', {
			slot = tostring(animal.slotId),
			animal = tostring(animalId),
			stand = tostring(animal.slotId),
		})
	end
	local state: { [string]: any } = {
		Valid = true,
		AnimalId = animalId,
		SlotId = animal.slotId,
		Name = displayName,
		Rarity = checked.rarity,
		Trait = trait,
		Level = animal.Level,
		LevelText = _displayLevel(animal),
		GenerationText = generationText,
		Mutations = mutations,
		SellValueRaw = sellValueRaw,
		Model = liveModel,
	}
	pcall(Remotes.FireClient, player, Remotes.Names.SellPreviewState, state)
	return state
end

-- Final confirmation: revalidate EVERYTHING through the
-- canonical pipeline (slot-owner + occupant + kind gates in
-- the handler, full transaction validation in SellAnimal)
-- and report the outcome for confirmation close/clear
-- decisions. Nothing published server-side needs cleanup
-- (the viewport clone lives client-side only).
function SellService.ConfirmSell(player: Player, animalId: string): { [string]: any }
	local result: { [string]: any } = { success = false, error = 'stale' }
	if Validation.LivePlayer(player) and type(animalId) == 'string' and animalId ~= '' and animalServiceRef then
		local animal: any = nil
		pcall(function()
			animal = animalServiceRef.Get(animalId)
		end)
		if type(animal) == 'table' and type(animal.slotId) == 'string' then
			local ok, r = pcall(SlotActionHandler.Handle, player, {
				Action = 'SellAnimal',
				SlotId = animal.slotId,
				OccupantId = animalId,
			})
			if ok and type(r) == 'table' then
				result = r
			end
		end
	end
	pcall(Remotes.FireClient, player, Remotes.Names.SellConfirmResult, {
		AnimalId = animalId,
		Success = result.success == true,
		Error = result.error,
	})
	return result
end

-- --- Egg sale: REMOVED -------------------------------------------
--
-- Eggs are NOT sellable. There is no SellEgg path, no egg
-- sell prompt, no egg sell button, and no egg sell remote:
-- every former entry point rejects (SlotActionHandler has
-- no 'SellEgg' branch; no prompt routes to it).
-- The authoritative animal pipeline above is the single
-- sale system.

return table.freeze(SellService)
