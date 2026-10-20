--!strict
--!native
--[[
	IncomeService
	=============
	Phase 2.6 — the ONE central income system. Animals generate
	income over time; the income accumulates in the OWNING SLOT's
	CashPool (profile record field, BigNumber string); the slot's
	CashCollector part holds the collectible cash; a player touching
	the collector transfers the whole pool into their Money.

	Separation of concepts (spec §2):
	  * Money            — the player's wallet (profile.Data.Money).
	                       Only EconomyService mutates it.
	  * CashPool         — per-Animal accumulated-but-uncollected
	                       cash (record.CashPool). Never auto-added
	                       to Money; it rides the Animal record,
	                       so slot rearrangement moves it for free
	                       (SetAnimalSlot mutates the same record).
	  * IncomePerSecond  — DERIVED, never persisted:
	                       AnimalStats.Calculate(record, 'Income')
	                       (definition -> rarity -> Stats.Income ->
	                       Level points -> StatCalculator).
	  * Offline Earnings — the offline window computed at rejoin,
	                       credited into the SAME CashPools. Kept a
	                       separate accumulation path from the
	                       online tick so Phase 2.7 multipliers can
	                       exclude it cleanly (see MULTIPLIER RULE).

	Ownership & authority:
	  * Server-authoritative end to end. There is no remote: the
	    client reads the pool via the `CashPool` string attribute on
	    each slot's CashCollector part (attributes replicate free);
	    touch collection is resolved entirely server-side.
  * Phase 2.6.2: the same publish boundary mirrors the value
    into the stand's display label — MAIN GAME:
    `Stand.Button.PressPart.SurfaceGui.Amount` (legacy:
    `CashCollector.CollectorGui.MoneyLabel`) —
    '$' .. BigNumber.Format(pool), display only,
	    never arithmetic, no multiplier applied on display. A
	    missing GUI chain warns once per part and otherwise fails
	    safely.
	  * Exactly ONE background loop (task.spawn in Start). No
	    per-Animal connections, no Workspace scans, no per-tick
	    DataStore writes (the only periodic profile write is the
	    LastSeen heartbeat, every OfflineHeartbeatSeconds).

	MULTIPLIER RULE (spec §68 — implemented in Phase 2.7):
	  * The Money multiplier (ModifierService.GetMoneyMultiplier)
	    applies ONLY inside the online tick, resolved once per
	    player in _tickPlayer and folded into newly generated income
	    at the moment it is credited into a CashPool (_creditPool).
	    It NEVER applies in ApplyOfflineEarnings and NEVER at
	    collection — TryCollect passes {ApplyMultiplier = false} so
	    the pool's already-shaped value transfers 1:1 into Money.
	  * Changing the multiplier never revalues the existing pool or
	    the fractional remainder (both are already in dollar space).

	Crash safety & exactly-once:
	  * Offline duration comes from the captured LastSeen consumed
	    once via PlayerService.ConsumeOfflineTimestamp — a window
	    can never pay twice, and a crash loses at most
	    OfflineHeartbeatSeconds of credit (never gains).
	  * Collection is atomic: a claim lock serializes each slot;
	    the pool is zeroed ONLY after EconomyService reports
	    success; on failure the pool is preserved and a warn is
	    logged. An empty pool touch is a silent no-op.

	Settlement (spec §45): removal must never silently delete
	accumulated cash. Bootstrap injects SettleAnimalPool into
	PlayerService.SetAnimalPoolSettlementHandler so every
	Animal-record removal transfers the pool to Money first.
	WipeUser deliberately does NOT settle (admin fresh-start nuke).
]]

local Players = game:GetService('Players')

local EconomyConfig = require(script.Parent.Parent.ReplicatedStorage.Config.Economy.Money)
local BigNumber = require(script.Parent.Parent.ReplicatedStorage.Utility.BigNumber)
local AnimalStats = require(script.Parent.Parent.ReplicatedStorage.Utility.AnimalStats)
local Validation = require(script.Parent.Parent.ReplicatedStorage.Utility.Validation)
local Debug = require(script.Parent.Parent.ReplicatedStorage.Utility.Debug)
local TransactionReason = require(script.Parent.Parent.ReplicatedStorage.Types.TransactionReason)
local SlotType = require(script.Parent.Parent.ReplicatedStorage.Types.SlotType)

-- Instant collection feedback (SFX + VFX + button press),
-- fired ONLY on the success branch below. Dependency-free
-- leaf module (no service refs, never throws), so a direct
-- require is cycle-safe.
local CollectFeedback = require(script.Parent.Base.CollectFeedback)
-- Shared remote registry (Signal/Validation/Debug only —
-- cycle-safe). Used for the CashCollected HUD trigger.
local Remotes = require(script.Parent.Parent.ReplicatedStorage.Utility.Remotes)
-- Shared MoneyIcon visual-config resolver (single
-- implementation; Codes/DailyRewards reuse it for their
-- CashCollected bursts).
local MoneyIcon = require(script.Parent.Utility.MoneyIcon)

local IncomeService = {}

-- --- Injected service refs (wired by bootstrap) -------------------

local playerServiceRef: any = nil
local economyServiceRef: any = nil
local slotServiceRef: any = nil
local baseServiceRef: any = nil
local animalServiceRef: any = nil
-- Phase 2.7: the ONE reader of the Money multiplier. Resolved once
-- per player per tick and folded into NEWLY generated income only.
-- The offline path, collection, and settlement never read this ref.
local modifierServiceRef: any = nil

function IncomeService.SetPlayerService(ps: any)
	playerServiceRef = ps
end

function IncomeService.SetEconomyService(es: any)
	economyServiceRef = es
end

function IncomeService.SetSlotService(ss: any)
	slotServiceRef = ss
end

function IncomeService.SetBaseService(bs: any)
	baseServiceRef = bs
end

function IncomeService.SetAnimalService(svc: any)
	animalServiceRef = svc
end

-- Phase 2.7: inject the centralized modifier authority. Nil-safe:
-- an unwired ref resolves every player to 1x (pre-2.7 behavior).
function IncomeService.SetModifierService(ms: any)
	modifierServiceRef = ms
end

-- --- Internal state ------------------------------------------------

local _started = false

-- Fractional income remainder per source. Money is integer-only
-- (BigNumber), but rates are floats; the remainder carries forward
-- so no income is ever lost to flooring (spec §12). Key:
-- '<userId>:<animalId>'.
local _frac: { [string]: number } = {}

-- collectorPart -> slot record. Filled by _registerCollectors; the
-- map (not a Workspace scan) is how a touch resolves back to its
-- slot.
local _collectorByPart: { [BasePart]: any } = {}

-- Per-player collection debounce (multi-body-part touches land in
-- the same instant; this collapses them into one collection).
local _lastTouch: { [number]: number } = {}

-- slotId -> true while a collection on that slot is in progress.
local _claims: { [string]: boolean } = {}

-- collectorPart -> last published CashPool string (change-detects
-- replication so attributes are not re-written every sweep).
local _published: { [BasePart]: string } = {}

local _lastPublishSweep = 0

-- --- Helpers -------------------------------------------------------

-- Find a persisted Animal record by Id in a player's list.
local function _findRecordById(records: { any }, id: any): any?
	if type(id) ~= 'string' then
		return nil
	end
	for _, record in ipairs(records) do
		if type(record) == 'table' and record.Id == id then
			return record
		end
	end
	return nil
end

-- Climb from the touched part to the Player whose character it
-- belongs to (handles accessory Handles: Handle -> Accessory ->
-- Character). Server-side touch resolution only — a touch from
-- anything that is not a character body part resolves to nil.
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

-- Warn once per part when the cash trigger's display chain
-- (SurfaceGui.Amount, legacy CollectorGui.MoneyLabel) is
-- missing or is not a TextLabel. The attribute still publishes
-- either way; the warn exists so a Studio setup gap is visible
-- without spamming (Phase 2.6.2).
local _labelWarned: { [BasePart]: boolean } = {}

-- Mirror one published pool value into the slot's display
-- label. MAIN GAME shape first:
-- `Stand.Button.PressPart.SurfaceGui.Amount`. Legacy fallback:
-- the pre-stand `CashCollector.CollectorGui.MoneyLabel`.
-- Display ONLY: this writes Text and nothing else — the value
-- is the authoritative pool string, formatted by
-- BigNumber.Format (string-based, never tonumber), with no
-- multiplier applied (spec §13: the label shows what is
-- stored, not what a multiplier "would" pay). A missing GUI
-- chain fails safely and warns at most once per part.
local function _mirrorLabel(part: BasePart, value: string)
	local text = '$' .. BigNumber.Format(value)
	local surfaceGui = part:FindFirstChild('SurfaceGui')
	local amountLabel = surfaceGui and surfaceGui:FindFirstChild('Amount')
	if amountLabel and amountLabel:IsA('TextLabel') then
		_labelWarned[part] = nil
		(amountLabel :: TextLabel).Text = text
		return
	end
	local gui = part:FindFirstChild('CollectorGui')
	local label = gui and gui:FindFirstChild('MoneyLabel')
	if label and label:IsA('TextLabel') then
		_labelWarned[part] = nil
		(label :: TextLabel).Text = text
		return
	end
	if not _labelWarned[part] then
		_labelWarned[part] = true
		Debug.Warn(
			'IN',
			'Cash trigger has no SurfaceGui.Amount (or legacy CollectorGui.MoneyLabel) TextLabel; pool value not displayed',
			{
				part = part:GetFullName(),
				guiMissing = tostring(surfaceGui == nil and gui == nil),
			}
		)
	end
end

-- Publish one slot's pool to its CashCollector attribute AND
-- mirror it into the slot's existing CollectorGui.MoneyLabel.
-- The server is authoritative; clients only read — server-written
-- attributes and Text replicate to clients for free. A slot with
-- no collector part or no live pool publishes nothing here.
local function _publishSlot(slot: any, value: string)
	local part = slot and slot.cashCollector
	if not part then
		return
	end
	if _published[part] == value then
		return
	end
	_published[part] = value
	part:SetAttribute('CashPool', value)
	_mirrorLabel(part, value)
end

-- Resolve the pool string that SHOULD be visible on a slot right
-- now ('0' for anything that is not an occupied Animal slot).
local function _slotPoolValue(slot: any): string
	if
		slot.state == SlotType.State.Occupied
		and slot.occupantKind == SlotType.OccupantKind.Animal
		and Validation.IsValidPlayerUserId(slot.ownerUserId)
	then
		local data = playerServiceRef and playerServiceRef.GetPlayerData(slot.ownerUserId)
		local record = data and _findRecordById(data.Brainrots, slot.occupantId)
		if record and record.Type == 'Brainrot' then
			return BigNumber.sanitize(record.CashPool) or '0'
		end
	end
	return '0'
end

-- Throttled replication sweep: every slot's CashPool attribute
-- converges to its authoritative value at most once per
-- CashPoolAttributeThrottleSeconds. Collection / offline
-- application publish their slots immediately (bypassing this
-- throttle via _publishSlot).
local function _sweepPublish()
	local now = os.clock()
	if now - _lastPublishSweep < EconomyConfig.CashPoolAttributeThrottleSeconds then
		return
	end
	_lastPublishSweep = now
	if not baseServiceRef then
		return
	end
	for _, base in pairs(baseServiceRef.GetAllBases()) do
		for _, slot in pairs(base.slots) do
			_publishSlot(slot, _slotPoolValue(slot))
		end
		-- Arena pools refresh on the same throttle: without
		-- this, an arena PressPart.SurfaceGui.Amount only
		-- moves on transitions/collection instead of every
		-- sweep like normal stands.
		if type(base.arenaSlots) == 'table' then
			for _, slot in pairs(base.arenaSlots) do
				_publishSlot(slot, _slotPoolValue(slot))
			end
		end
	end
end

-- Recompute and publish ONE slot's pool right now (attribute +
-- MoneyLabel). The SlotService display hook (Phase 2.6.2) calls
-- this on every slot transition that changes what a collector
-- displays — place, pickup (Demote), move, release — so the
-- visible label follows the authoritative state the instant the
-- transition lands instead of waiting for the next throttled
-- sweep. Collection and offline application already publish
-- directly; this covers the transition paths. No-op on any
-- unexpected shape, so a slot transition can never break.
function IncomeService.RepublishSlot(slot: any)
	if not slot then
		return
	end
	_publishSlot(slot, _slotPoolValue(slot))
end

-- Credit `whole` whole dollars into a record's CashPool. THE ONE
-- accumulation boundary. The Phase 2.7 Money multiplier is folded
-- into the RATE upstream in _tickPlayer (rate * mult * elapsed) so
-- by the time `whole` arrives here it is already shaped — and must
-- never be shaped again. The offline path deliberately bypasses the
-- multiplier entirely (see MULTIPLIER RULE).
local function _creditPool(record: any, whole: number)
	local current = BigNumber.sanitize(record.CashPool) or '0'
	local earned = BigNumber.sanitize(tostring(whole)) or '0'
	record.CashPool = BigNumber.Add(current, earned)
end

-- Is this persisted record currently earning for this user? The
-- full eligibility chain (spec §8): an Animal record, not being
-- carried, on an Occupied slot owned by this user, as an Animal
-- occupant. Eggs never earn; carried Animals earn 0
-- (their pool is preserved and resumes on place).
local function _isEligible(userId: number, record: any, carriedId: string?): boolean
	if type(record) ~= 'table' or record.Type ~= 'Brainrot' then
		return false
	end
	if carriedId and record.Id == carriedId then
		return false
	end
	-- Active Arena deployment: a deployed animal's CashPool
	-- is FROZEN (never reset, never deleted) and earns
	-- nothing while fighting; generation resumes on restore.
	-- One gate covers the online tick AND offline earnings
	-- (both flow through this eligibility chain). Guarded for
	-- test doubles that only stub slot/player services.
	if animalServiceRef and animalServiceRef.IsArenaDeployed then
		local depOk, deployed = pcall(animalServiceRef.IsArenaDeployed, record.Id)
		if depOk and deployed == true then
			return false
		end
	end
	if not slotServiceRef then
		return false
	end
	local slot = slotServiceRef.FindSlotByOccupant(record.Id)
	if not slot then
		return false
	end
	-- Arena stands are first-class slots: arena-team animals
	-- earn through this exact chain (same rate, same pool).
	-- Location never duplicates income — one record, one
	-- registration, one tick.
	if slot.ownerUserId ~= userId then
		return false
	end
	if slot.state ~= SlotType.State.Occupied or slot.occupantKind ~= SlotType.OccupantKind.Animal then
		return false
	end
	return true
end

-- --- Tick (online accumulation) ------------------------------------

-- Advance ONE player's sources by `elapsed` real seconds. Exposed
-- via TickSources below; kept here so the eligibility chain, the
-- fractional accumulator and the heartbeat live in one place.
local function _tickPlayer(userId: number, elapsed: number)
	local data = playerServiceRef and playerServiceRef.GetPlayerData(userId)
	if not data then
		return
	end

	-- Crash-bound the offline anchor while the player is online:
	-- refresh LastSeen at most every OfflineHeartbeatSeconds so a
	-- crashed server loses at most that much offline credit.
	local lastSeen = data.LastSeen
	if type(lastSeen) == 'number' and os.time() - lastSeen >= EconomyConfig.OfflineHeartbeatSeconds then
		data.LastSeen = os.time()
	end

	local carried = animalServiceRef and animalServiceRef.GetCarriedAnimalByUserId(userId)
	local carriedId = carried and carried.uniqueId or nil

	-- Phase 2.7: resolve the player's Money multiplier ONCE per tick.
	-- It scales the RATE of newly generated income below — the
	-- fractional remainder is already in whole-dollar space, so a
	-- multiplier change can never retroactively revalue it, and the
	-- existing pool is never touched here (only added to). Untrusted
	-- resolution degrades to 1x; the multiplier is validated
	-- finite-and-positive at the ModifierService boundary.
	local moneyMult = 1
	if modifierServiceRef and modifierServiceRef.GetMoneyMultiplier then
		local ok, resolved = pcall(modifierServiceRef.GetMoneyMultiplier, userId)
		if ok and type(resolved) == 'number' and resolved == resolved and resolved > 0 and resolved ~= math.huge then
			moneyMult = resolved
		end
	end

	-- Snapshot the array (not the records): a concurrent
	-- Add/Remove cannot confuse the loop, and the records are
	-- shared references so credited pools land in the profile.
	local records = table.clone(data.Brainrots)
	for _, record in ipairs(records) do
		if _isEligible(userId, record, carriedId) then
			local rate = AnimalStats.Calculate(record, 'Income')
			if rate > 0 then
				local key = tostring(userId) .. ':' .. tostring(record.Id)
				local acc = (_frac[key] or 0) + rate * moneyMult * elapsed
				local whole = math.floor(acc)
				if whole >= 1 then
					_frac[key] = acc - whole
					_creditPool(record, whole)
				else
					_frac[key] = acc
				end
			end
		end
	end
end

-- Advance every (or the given) player's sources by `elapsed` real
-- seconds. `userIds` is the testability seam: production callers
-- pass nothing and the current player list is used. Runs
-- synchronously and yield-free.
function IncomeService.TickSources(elapsed: number, userIds: { number }?)
	if type(elapsed) ~= 'number' or elapsed ~= elapsed or elapsed <= 0 then
		return
	end
	local list = userIds or {}
	if not userIds then
		for _, player in ipairs(Players:GetPlayers()) do
			list[#list + 1] = player.UserId
		end
	end
	for _, userId in ipairs(list) do
		_tickPlayer(userId, elapsed)
	end
end

-- --- Offline earnings ----------------------------------------------

-- Compute and credit the offline window for a player into their
-- Animals' CashPools (NOT Money). Called by bootstrap after the
-- base is restored, BEFORE the loaded state is pushed — the client
-- never sees a pool that does not include offline earnings.
--
-- Contract (spec §31-§40):
--   * MAX_OFFLINE_SECONDS caps the window; excess time pays
--     nothing extra.
--   * Not affected by any Money multiplier — see MULTIPLIER RULE.
--   * Same eligibility chain as the online tick (Phase 2.7.1):
--     carried, slotless, wrong-owner, and non-Animal records
--     earn nothing.
--   * Generates NO XP, NO levels, NO stat changes: this function
--     only writes CashPool.
--   * A missing/malformed anchor (captured <= 0) pays nothing.
--   * The timestamp is consumed exactly once (ConsumeOffline-
--     Timestamp), so the same period can never pay twice.
function IncomeService.ApplyOfflineEarnings(player: Player)
	if not playerServiceRef then
		return
	end
	local userId = player.UserId
	local captured = playerServiceRef.ConsumeOfflineTimestamp(userId)
	if captured <= 0 then
		Debug.Log('IN', 'ApplyOfflineEarnings: no usable offline anchor; paying nothing', {
			userId = tostring(userId),
		})
		return
	end

	local rawDuration = os.time() - captured
	local duration = math.clamp(rawDuration, 0, EconomyConfig.MaxOfflineSeconds)
	if duration <= 0 then
		return
	end
	if rawDuration > EconomyConfig.MaxOfflineSeconds then
		Debug.Log('IN', 'offline window capped at MaxOfflineSeconds', {
			userId = tostring(userId),
			raw = tostring(rawDuration),
			capped = tostring(EconomyConfig.MaxOfflineSeconds),
		})
	end

	local data = playerServiceRef.GetPlayerData(userId)
	if not data then
		return
	end

	-- Offline eligibility (Phase 2.7.1): the SAME chain as the
	-- online tick. A carried animal earns nothing (its pool is
	-- preserved and resumes on place); a record with no live
	-- Occupied slot owned by this user (e.g. skipped at restore —
	-- kept but unplaceable) earns nothing. In production both
	-- guards are vacuous at join time — carry cannot survive
	-- disconnect (CleanupPlayer recovers the animal and clears
	-- the registry) and RestorePlayerBase just occupied the slots
	-- — but the chain is now uniform by construction instead of
	-- by bootstrap-ordering luck.
	-- Offline path: wallet multiplier at OfflineEffectiveness
	-- (balance pass: ~50% of equivalent online income), still
	-- no XP and no stats. Same 1x fallback as the live tick.
	local moneyMult = 1
	if modifierServiceRef and modifierServiceRef.GetMoneyMultiplier then
		local okM, resolved = pcall(modifierServiceRef.GetMoneyMultiplier, userId)
		if okM and type(resolved) == 'number' and resolved == resolved and resolved > 0 and resolved ~= math.huge then
			moneyMult = resolved
		end
	end
	local effectiveness = EconomyConfig.OfflineEffectiveness
	if type(effectiveness) ~= 'number' or effectiveness ~= effectiveness or effectiveness < 0 or effectiveness > 1 then
		effectiveness = 0.5
	end
	local carried = animalServiceRef and animalServiceRef.GetCarriedAnimalByUserId(userId)
	local carriedId = carried and carried.uniqueId or nil
	local credited = 0
	local records = table.clone(data.Brainrots)
	for _, record in ipairs(records) do
		if _isEligible(userId, record, carriedId) then
			local rate = AnimalStats.Calculate(record, 'Income')
			if rate > 0 then
				local earned = math.floor(rate * moneyMult * effectiveness * duration)
				if earned > 0 then
					_creditPool(record, earned)
					credited += 1
					-- Force-publish so the collector shows the
					-- combined pool the moment the client loads.
					if slotServiceRef then
						local slot = slotServiceRef.FindSlotByOccupant(record.Id)
						if slot then
							_publishSlot(slot, BigNumber.sanitize(record.CashPool) or '0')
						end
					end
				end
			end
		end
	end
	Debug.Log('IN', 'offline earnings applied into CashPools', {
		userId = tostring(userId),
		captured = tostring(captured),
		durationSeconds = tostring(duration),
		animalsCredited = tostring(credited),
	})
end

-- --- Collection -----------------------------------------------------

-- Attempt to collect the pool of `slot` for `player`. The full
-- validation chain (spec §17): live slot re-read, ownership, kind,
-- record resolution, claim lock, per-player debounce. An empty
-- pool is a silent no-op; a wrong-owner touch is a silent no-op;
-- only real state inconsistencies warn.
--
-- Atomicity (spec §19): the claim lock serializes concurrent
-- touches on one slot; the pool is zeroed ONLY after AddMoney
-- reports success; on failure the pool is preserved untouched.
--
-- Deliberately SILENT on rejection (no NotificationService): this is a
-- touch-driven path firing at high frequency while a character
-- stands on the collector — empty pool, debounce, and claim-lock
-- are all normal state, and a toast per touch would be pure
-- spam. Only genuine state inconsistencies warn (server-side).
function IncomeService.TryCollect(slot: any, player: Player)
	if not slot or not player then
		return
	end
	-- Death lockout: a dead body lying on a collector collects
	-- nothing (Touched still fires for corpses). Table shims
	-- (tests) pass through; engine Players are fully gated.
	if not Validation.CanPlayerInteract(player) then
		return
	end
	local userId = player.UserId
	if type(slot.ownerUserId) ~= 'number' or slot.ownerUserId ~= userId then
		-- Not this player's collector — silent no-op.
		return
	end
	if slot.state ~= SlotType.State.Occupied or slot.occupantKind ~= SlotType.OccupantKind.Animal then
		return
	end
	if not playerServiceRef or not economyServiceRef then
		return
	end

	-- Per-player debounce: every body part of one touch lands
	-- here within the same instant; one collection.
	local now = os.clock()
	local last = _lastTouch[userId]
	if last and now - last < EconomyConfig.CollectorDebounceSeconds then
		return
	end
	_lastTouch[userId] = now

	-- Claim lock: one collection per slot at a time.
	if _claims[slot.id] then
		return
	end
	_claims[slot.id] = true

	local ok, err = pcall(function()
		local data = playerServiceRef.GetPlayerData(userId)
		if not data then
			return
		end
		local record = _findRecordById(data.Brainrots, slot.occupantId)
		if not record then
			-- Slot claims an occupant the profile does not know:
			-- a state inconsistency worth a loud warn.
			Debug.Warn('IN', 'TryCollect: occupied slot has no matching Animal record', {
				userId = tostring(userId),
				slotId = tostring(slot.id),
				occupantId = tostring(slot.occupantId),
			})
			return
		end
		local pool = BigNumber.sanitize(record.CashPool) or '0'
		if BigNumber.IsZero(pool) then
			-- Empty pool: silent no-op, no transaction.
			return
		end
		-- TRANSFER, not a grant: {ApplyMultiplier = false} so the
		-- Money multiplier can never apply twice (see
		-- MULTIPLIER RULE). Zero the pool ONLY on success.
		local result =
			economyServiceRef.AddMoney(userId, pool, TransactionReason.CashCollector, { ApplyMultiplier = false })
		if result and result.Success then
			record.CashPool = '0'
			_publishSlot(slot, '0')
			-- Successful commit: trigger instant feedback
			-- (CashClaim SFX + VFX + physical button press)
			-- synchronously on this branch — never on empty,
			-- failed, or rejected claims (all of them returned
			-- above). Never throws; UI refresh already landed
			-- via _publishSlot above.
			pcall(CollectFeedback.Play, player, slot)
			-- Authoritative HUD trigger: the collecting player
			-- ONLY. Carries the committed pool (BigNumber) +
			-- the resolved icon id; the money itself still
			-- arrives via the PlayerState push, which stays
			-- the animation target. Never throws (a missing
			-- client or remote must not break the claim).
			pcall(function()
				-- World origin of the collection (the cash
				-- trigger's position): the client converts it
				-- to screen space so icons burst FROM the
				-- button, never from a guessed screen point.
				local origin: { number }? = nil
				local trigger = slot.cashCollector
				if typeof(trigger) == 'Instance' and (trigger :: Instance):IsA('BasePart') then
					local pos = (trigger :: BasePart).Position
					origin = { pos.X, pos.Y, pos.Z }
				end
				Remotes.FireClient(player, Remotes.Names.CashCollected, {
					Amount = pool,
					NewMoney = (result and type(result.NewMoney) == 'string' and result.NewMoney) or nil,
					Icon = MoneyIcon.Resolve(),
					Origin = origin,
				})
			end)
			Debug.Log('IN', 'cash collected', {
				userId = tostring(userId),
				slotId = tostring(slot.id),
				animalId = tostring(record.Id),
				amount = pool,
			})
		else
			Debug.Warn('IN', 'TryCollect: AddMoney failed; pool preserved', {
				userId = tostring(userId),
				slotId = tostring(slot.id),
				pool = pool,
				code = tostring(result and result.Code),
			})
		end
	end)
	_claims[slot.id] = nil
	if not ok then
		Debug.Warn('IN', 'TryCollect: unexpected error', {
			userId = tostring(userId),
			slotId = tostring(slot.id),
			error = tostring(err),
		})
	end
end

-- --- Collector registration -----------------------------------------

-- ONE Touched connection per collector part, taken at Start().
-- Re-running is a no-op (the map is the idempotence guard).
local function _registerOne(slot: any)
	local part = slot and slot.cashCollector
	if part and not _collectorByPart[part] then
		_collectorByPart[part] = slot
		part.Touched:Connect(function(hit)
			local ownerSlot = _collectorByPart[part]
			if not ownerSlot then
				return
			end
			local player = _playerFromHit(hit)
			if not player then
				return
			end
			IncomeService.TryCollect(ownerSlot, player)
		end)
	end
end

local function _registerCollectors()
	if not baseServiceRef then
		return
	end
	for _, base in pairs(baseServiceRef.GetAllBases()) do
		for _, slot in pairs(base.slots) do
			_registerOne(slot)
		end
		if type(base.arenaSlots) == 'table' then
			for _, slot in pairs(base.arenaSlots) do
				_registerOne(slot)
			end
		end
	end
end

-- Wire cash triggers for runtime-created slots (dynamic
-- StandPos architecture). BaseService calls this right after
-- building a base's runtime slots — Start() only saw the
-- parts that existed at boot. Idempotent per part: already
-- wired parts are skipped, destroyed parts simply never match
-- a touch. Never throws.
function IncomeService.EnsureCollectorsForSlots(slots: any)
	local ok, err = pcall(function()
		if type(slots) ~= 'table' then
			return
		end
		for _, slot in pairs(slots) do
			_registerOne(slot)
		end
	end)
	if not ok then
		Debug.Warn('IN', 'EnsureCollectorsForSlots failed', { error = tostring(err) })
	end
end

-- Forget cash triggers for runtime-destroyed slots. Dynamic
-- slot teardown calls this BEFORE the records are dropped so
-- the part-keyed maps never pin destroyed parts (or their
-- stale slot records) across reassignments. Never throws.
function IncomeService.ForgetCollectorsForSlots(slots: any)
	pcall(function()
		if type(slots) ~= 'table' then
			return
		end
		for _, slot in pairs(slots) do
			local part = slot and slot.cashCollector
			if part then
				_collectorByPart[part] = nil
				_published[part] = nil
			end
		end
	end)
end

-- --- Settlement (removal path) ---------------------------------------

-- Transfer a removed Animal's pool into its owner's Money.
-- Injected into PlayerService via SetAnimalPoolSettlementHandler
-- so every removal path (RemoveAnimal / RemoveAnimalAtSlot)
-- settles BEFORE the record leaves the profile. Failures warn and
-- preserve the value on the record — never a silent delete.
-- WipeUser does NOT route through here by design.
function IncomeService.SettleAnimalPool(userId: number, record: any)
	if type(record) ~= 'table' or record.Type ~= 'Brainrot' then
		return
	end
	local pool = BigNumber.sanitize(record.CashPool) or '0'
	if BigNumber.IsZero(pool) then
		return
	end
	if not economyServiceRef then
		Debug.Warn('IN', 'SettleAnimalPool: EconomyService not wired; pool value stays on record', {
			userId = tostring(userId),
			animalId = tostring(record.Id),
			pool = pool,
		})
		return
	end
	local result =
		economyServiceRef.AddMoney(userId, pool, TransactionReason.CashCollector, { ApplyMultiplier = false })
	if result and result.Success then
		record.CashPool = '0'
		-- The record is about to leave the profile; drop its
		-- fractional remainder so it cannot leak into a future
		-- record that reuses the key space.
		_frac[tostring(userId) .. ':' .. tostring(record.Id)] = nil
		Debug.Log('IN', 'pool settled on removal', {
			userId = tostring(userId),
			animalId = tostring(record.Id),
			amount = pool,
		})
	else
		Debug.Warn('IN', 'SettleAnimalPool: AddMoney failed; pool value preserved on record', {
			userId = tostring(userId),
			animalId = tostring(record.Id),
			pool = pool,
			code = tostring(result and result.Code),
		})
	end
end

-- Atomically consume an Animal's CashPool into a sale (Phase 2.8).
-- Reads the pool, zeroes it, clears the fractional remainder, and
-- publishes '0' — all under the slot's claim lock, so a racing
-- TryCollect either collects first (sale then consumes '0') or
-- loses the claim (collect then sees '0'): the $10,000 pays
-- EXACTLY ONCE either way. Returns (poolString) on success,
-- (nil, code) when there is nothing to consume.
--
-- Ownership/sellability is the CALLER's job (SellService validates
-- before calling); this function only guarantees the pool cannot
-- be double-spent. The caller MUST pay the returned pool into the
-- sale payout; on payment failure it must add the pool back onto
-- the (still live) record itself — this function never restores.
function IncomeService.ConsumePoolForSale(userId: number, animalId: string): (string?, string?)
	if type(animalId) ~= 'string' or not playerServiceRef or not slotServiceRef then
		return nil, 'unavailable'
	end
	local data = playerServiceRef.GetPlayerData(userId)
	local record = data and _findRecordById(data.Brainrots, animalId)
	if not record then
		return nil, 'not-found'
	end
	local slot = slotServiceRef.FindSlotByOccupant(animalId)
	if not slot or not slot.id then
		return nil, 'no-slot'
	end
	if _claims[slot.id] then
		-- A collection is mid-flight on this slot. Fail safe;
		-- the seller retries and then consumes the remainder.
		return nil, 'busy'
	end
	_claims[slot.id] = true
	local ok, pool = pcall(function()
		local value = BigNumber.sanitize(record.CashPool) or '0'
		record.CashPool = '0'
		-- The record is about to leave the profile; drop its
		-- fractional remainder so it cannot leak (same rule as
		-- SettleAnimalPool — a sale must not leave session
		-- residue behind).
		_frac[tostring(userId) .. ':' .. tostring(animalId)] = nil
		_publishSlot(slot, '0')
		return value
	end)
	_claims[slot.id] = nil
	if not ok then
		Debug.Warn('IN', 'ConsumePoolForSale: unexpected error', {
			userId = tostring(userId),
			animalId = tostring(animalId),
			error = tostring(pool),
		})
		return nil, 'error'
	end
	return pool, nil
end

-- --- Lifecycle ------------------------------------------------------

function IncomeService.Init()
	-- No-op: all wiring arrives via the Set* injectors.
end

-- Drop a player's per-session accumulators (debounce, fractional
-- remainders). Called by bootstrap on leave. Nothing here holds
-- pool value — the pool lives on the profile record.
function IncomeService.ForgetPlayer(userId: number)
	_lastTouch[userId] = nil
	local prefix = tostring(userId) .. ':'
	for key in pairs(_frac) do
		if string.sub(key, 1, #prefix) == prefix then
			_frac[key] = nil
		end
	end
end

-- Start the ONE background income loop. Idempotent. Must be
-- called AFTER RegisterBases (collector parts must exist).
function IncomeService.Start()
	if _started then
		return
	end
	_started = true
	_registerCollectors()
	-- Phase 2.6.2: initialize every collector's CashPool attribute
	-- AND MoneyLabel from the current authoritative pool at boot,
	-- bypassing the sweep throttle, so no label waits for the first
	-- income tick to show a value. A rejoin's slot occupancy
	-- republishes via the SlotService display hook, and offline
	-- application publishes its slots directly — both land before
	-- the loaded state is pushed.
	if baseServiceRef then
		for _, base in pairs(baseServiceRef.GetAllBases()) do
			for _, slot in pairs(base.slots) do
				_publishSlot(slot, _slotPoolValue(slot))
			end
			if type(base.arenaSlots) == 'table' then
				for _, slot in pairs(base.arenaSlots) do
					_publishSlot(slot, _slotPoolValue(slot))
				end
			end
		end
	end
	task.spawn(function()
		local lastClock = os.clock()
		while true do
			task.wait(EconomyConfig.IncomeTickSeconds)
			local now = os.clock()
			local elapsed = now - lastClock
			lastClock = now
			local ok, err = pcall(IncomeService.TickSources, elapsed)
			if not ok then
				Debug.Warn('IN', 'income tick errored', { error = tostring(err) })
			end
			pcall(_sweepPublish)
		end
	end)
	Debug.Log('IN', 'IncomeService started', {
		tickSeconds = tostring(EconomyConfig.IncomeTickSeconds),
		maxOfflineSeconds = tostring(EconomyConfig.MaxOfflineSeconds),
	})
end

return table.freeze(IncomeService)
