--!strict
--!native
--[[
	EconomyService
	==============
	The single authoritative mutator for the player's Money
	field on profile.Data.

	Why a service boundary:
	  * `Money` is a string-backed arbitrary-precision decimal.
	    Naive mutations scattered across services invite a
	    format-drift bug (one service uses `tonumber()` and
	    loses precision above 2^53).
	  * The old `CanAfford` + `DebitCash` two-step pattern used
	    in `EggService.Purchase` is racy: a second prompt
	    between the two checks can double-spend. `TrySpendMoney`
	    collapses the read, compare, and write into a single
	    critical section.
	  * Every grant/spend needs an audit reason so the Debug
	    log line tells us WHY a balance changed. The closed
	    `TransactionReason` enum makes typos fail at the
	    service boundary.

	Does NOT own:
	  * Profile loading (PlayerService)
	  * The persisted schema (PlayerService owns profile.Data
	    shape; this service just reads + writes the `Money`
	    field)
	  * The HUD wire format (BigNumber.Format lives in
	    ReplicatedStorage so clients can format without server
	    help)

 	Persistence shape (Phase 2.1):
 	  profile.Data.Money = '12345'           (string, BigNumber)
 	  profile.Data.Multipliers = { Money = 1 }   (DEPRECATED compat
 	    data, Phase 2.7.1 — see AddMoney below. Always 1 in
 	    legitimate profiles; no system writes any other value.)

	Concurrency model:
	  * Luau scripts run in a single coroutine, so two
	    simultaneous calls on the same userId from the same
	    script serialize on the VM. Cross-script calls (e.g.
	    Cmdr vs EggService) DO interleave; the critical
	    section here is "read -> compare -> write" with no
	    `task.yield()` between them, so a second call sees the
	    post-write balance. A future per-user mutation queue
	    (E0 follow-up) is the right place to fully lock this
	    down.
]]

local EconomyConfig = require(script.Parent.Parent.ReplicatedStorage.Config.Economy.Money)
local Debug = require(script.Parent.Parent.ReplicatedStorage.Utility.Debug)
local BigNumber = require(script.Parent.Parent.ReplicatedStorage.Utility.BigNumber)
local TransactionReason = require(script.Parent.Parent.ReplicatedStorage.Types.TransactionReason)

local Players = game:GetService('Players')

local EconomyService = {}

-- --- Late-bound service refs -----------------------------------
--
-- Set by bootstrap: `EconomyService.SetPlayerService(PlayerService)`
-- and `EconomyService.SetBaseService(BaseService)`. We don't
-- `require` them here to avoid circular imports (PlayerService
-- is required by bootstrap, and the service wires the two up
-- explicitly). EconomyService never mutates PlayerService state;
-- it only reads the per-user profile data through
-- `PlayerService.GetPlayerData`.
local _playerService: any? = nil

function EconomyService.SetPlayerService(playerService: any)
	_playerService = playerService
end

-- Snapshot provider for post-mutation replication (see
-- pushMoneyState below). Same late-bind pattern as
-- PlayerService: BaseService requires neither this service nor
-- its callers back, but the setter keeps the direction
-- explicit and keeps specs working with the ref unset.
local _baseService: any? = nil

function EconomyService.SetBaseService(baseService: any)
	_baseService = baseService
end

-- Post-mutation replication: EVERY successful balance write
-- pushes the canonical PlayerState (authoritative Money + a
-- fresh base snapshot) so the HUD cash label and the money
-- pool converge without each calling system remembering to
-- push. This is the root money pipeline — CodesService,
-- refunds, debits, and future grant systems all replicate
-- through here automatically; the explicit per-transaction
-- pushes callers already make remain as fuller end-of-flow
-- syncs (idempotent, already the norm).
--
-- Best-effort and infallible by construction: skipped when a
-- ref is unset (specs), when the player is gone, or before a
-- base is assigned (join-time seeding is covered by
-- bootstrap's own post-load push). pcall-guarded so
-- replication can never fail the money transaction itself.
local function pushMoneyState(userId: number)
	if _playerService == nil or _baseService == nil then
		return
	end
	pcall(function()
		local player = Players:GetPlayerByUserId(userId)
		if player == nil then
			return
		end
		if _playerService.GetBaseId(userId) == nil then
			return
		end
		_playerService.PushState(player, _baseService.Snapshot(userId))
	end)
end

-- --- Public types ------------------------------------------------

-- The structured result of every money mutation. Every caller
-- (Cmdr, services, test specs) must check `.Success` before
-- reading `.NewMoney` (it's nil on failure).
export type EconomyResult = {
	Success: boolean,
	NewMoney: string?,
	Reason: string,
	Code: string?,
	TransactionId: string?,
}

-- --- Internal helpers --------------------------------------------

-- 64-bit-style transaction id. Built from the user's UserId
-- + os.clock() + a per-service monotonic counter. Good enough
-- to grep for in the Debug stream; not a UUID, not collision-
-- safe under adversarial load.
local _txCounter: number = 0
local function _newTransactionId(userId: number): string
	_txCounter = _txCounter + 1
	return string.format('tx-%d-%d', userId, _txCounter)
end

-- Build a failed EconomyResult.
local function _fail(reason: string, code: string, transactionId: string): EconomyResult
	Debug.Warn('EC', 'money op failed', {
		reason = reason,
		code = code,
		tx = transactionId,
	})
	return {
		Success = false,
		NewMoney = nil,
		Reason = reason,
		Code = code,
		TransactionId = transactionId,
	}
end

-- Build a successful EconomyResult. The `newMoney` is the
-- post-write balance.
local function _ok(reason: string, newMoney: string, transactionId: string): EconomyResult
	Debug.Log('EC', 'money op ok', {
		reason = reason,
		newMoney = newMoney,
		tx = transactionId,
	})
	return {
		Success = true,
		NewMoney = newMoney,
		Reason = reason,
		Code = nil,
		TransactionId = transactionId,
	}
end

-- --- Singleton API ------------------------------------------------

function EconomyService.Init()
	-- No-op: nothing to pre-warm. We just expose entry points.
	-- The PlayerService ref is set by bootstrap; the service
	-- fails every call until then.
end

-- --- Reads --------------------------------------------------------

-- Return the player's Money as a canonical BigNumber string.
-- If the player is not loaded, returns "0" — never nil, never
-- an error. Callers can pass the result straight into
-- BigNumber.Format for display.
function EconomyService.GetMoney(userId: number): string
	if not _playerService then
		return '0'
	end
	local data = _playerService.GetPlayerData(userId)
	if not data then
		return '0'
	end
	-- Reconcile a freshly-loaded profile that hasn't seen the
	-- reconcile pass yet (the reconcile in LoadPlayerData
	-- sets the starting money; this is a defensive second
	-- chance in case a caller reads before reconcile).
	if type(data.Money) ~= 'string' then
		return '0'
	end
	-- Canonicalize: strip leading zeros, "0" for empty.
	local sanitized = BigNumber.sanitize(data.Money)
	return sanitized or '0'
end

-- Compare the player's Money to a cost. Returns true iff
-- Money >= cost. Both arguments are BigNumber strings. This
-- is a non-mutating read; the side-effecting spend path is
-- `TrySpendMoney`.
function EconomyService.CanAfford(userId: number, cost: string): boolean
	if type(cost) ~= 'string' then
		return false
	end
	local sanitizedCost = BigNumber.sanitize(cost)
	if not sanitizedCost then
		return false
	end
	local current = EconomyService.GetMoney(userId)
	if BigNumber.IsZero(sanitizedCost) then
		-- A zero-cost purchase is always affordable.
		return true
	end
	local cmp = BigNumber.Compare(current, sanitizedCost)
	return cmp >= 0
end

-- --- Mutations ----------------------------------------------------

-- Add `amount` (BigNumber string) to the player's Money for
-- the given audit reason. If the resulting balance would
-- exceed `EconomyConfig.MaxMoney`, the result is clamped to
-- `MaxMoney` and `Code = 'cap-exceeded'` is set; the
-- transaction is still successful (the player got the
-- money they were granted, just not over the cap).
--
-- Optional `opts.ApplyMultiplier` (default true) reads the
-- DEPRECATED `profile.Data.Multipliers.Money` compat field
-- (Phase 2.7.1). It is NOT the live modifier system:
-- ModifierService is the single authority for Money/XP
-- modifiers, read at the two application points (online income
-- generation in IncomeService, grants in AnimalService.AddXP).
-- This egg is retained byte-for-byte for backward
-- compatibility (locked EconomyService.spec behavior + old
-- profiles that still carry the field, which is always 1
-- legitimately). New systems must NEVER write to or depend on
-- `profile.Data.Multipliers` — add a ModifierService source.
function EconomyService.AddMoney(
	userId: number,
	amount: string,
	reason: string,
	opts: { ApplyMultiplier: boolean? }?
): EconomyResult
	local tx = _newTransactionId(userId)
	-- Validate the reason FIRST so a typo in a Cmdr command
	-- can't change a player's Money.
	if not TransactionReason.isValid(reason) then
		return _fail(reason, 'invalid-reason', tx)
	end
	if not _playerService then
		return _fail(reason, 'no-profile', tx)
	end
	local data = _playerService.GetPlayerData(userId)
	if not data then
		return _fail(reason, 'no-profile', tx)
	end
	if type(amount) ~= 'string' then
		return _fail(reason, 'invalid-amount', tx)
	end
	local sanitizedAmount = BigNumber.sanitize(amount)
	if not sanitizedAmount then
		return _fail(reason, 'invalid-amount', tx)
	end

	-- Apply multiplier (DEPRECATED compat path, Phase 2.7.1 —
	-- see the doc comment above. Default 1; the live income/XP
	-- transactions that reach the pool always pass
	-- { ApplyMultiplier = false }, so this egg can never
	-- double-shape ModifierService-shaped income.)
	local applyMult = true
	if opts and opts.ApplyMultiplier ~= nil then
		applyMult = opts.ApplyMultiplier and true or false
	end
	if applyMult and data.Multipliers and type(data.Multipliers.Money) == 'number' then
		local mult = data.Multipliers.Money
		-- Guard against non-integer / negative multipliers.
		-- Multiplier = 0 is a legitimate "kill the grant"
		-- signal (used by future event systems to silently
		-- absorb a reward), so it goes through.
		if mult < 0 or mult ~= math.floor(mult) then
			return _fail(reason, 'invalid-amount', tx)
		end
		if mult ~= 1 then
			sanitizedAmount = BigNumber.Multiply(sanitizedAmount, mult)
		end
	end

	-- If the (possibly multiplied) amount is zero, no-op
	-- success. The player's balance is unchanged but the
	-- transaction is still logged for audit.
	if BigNumber.IsZero(sanitizedAmount) then
		return _ok(reason, EconomyService.GetMoney(userId), tx)
	end

	-- Compute the new balance and cap it.
	local current = EconomyService.GetMoney(userId)
	local sum = BigNumber.Add(current, sanitizedAmount)
	local maxMoney = BigNumber.sanitize(EconomyConfig.MaxMoney) or '0'
	local capped = false
	if BigNumber.Compare(sum, maxMoney) > 0 then
		sum = maxMoney
		capped = true
	end

	-- Critical section: write to profile.Data.Money. There
	-- is no `task.yield()` between this read-then-write and
	-- the prior read above, so a second concurrent call on
	-- the same userId in the same script will see the
	-- post-write value when it runs.
	data.Money = sum

	-- Root replication: the balance changed, so the canonical
	-- PlayerState (and therefore the cash UI) follows through
	-- the one money pipeline — no caller action required.
	pushMoneyState(userId)

	if capped then
		Debug.Warn('EC', 'cap-exceeded', {
			reason = reason,
			requested = sanitizedAmount,
			newBalance = sum,
			maxMoney = maxMoney,
			tx = tx,
		})
		local result = _ok(reason, sum, tx)
		result.Code = 'cap-exceeded'
		return result
	end
	return _ok(reason, sum, tx)
end

-- Atomic compare-and-debit. Reads the balance, compares to
-- `cost`, and writes the new balance in a single critical
-- section with no `task.yield()` between them. On
-- insufficient funds, returns `Success = false` and DOES
-- NOT mutate the balance. The `AllowNegative` opt is a
-- future-extension hook for "borrowed money" flows (e.g.
-- a bank loan); the default is false.
--
-- On success, the reason in the audit log is whatever the
-- caller passed (e.g. `EggPurchase`).
--
-- `opts.AllowNegative` is reserved for future flows
-- (e.g. a bank loan). Today the BigNumber Subtract is
-- always clamped at "0" regardless, so the flag has no
-- observable effect; it is accepted so a future caller
-- can opt in without changing the signature.
-- selene: allow(unused_variable)
function EconomyService.TrySpendMoney(
	userId: number,
	cost: string,
	reason: string,
	opts: { AllowNegative: boolean? }?
): EconomyResult
	local tx = _newTransactionId(userId)
	if not TransactionReason.isValid(reason) then
		return _fail(reason, 'invalid-reason', tx)
	end
	if not _playerService then
		return _fail(reason, 'no-profile', tx)
	end
	local data = _playerService.GetPlayerData(userId)
	if not data then
		return _fail(reason, 'no-profile', tx)
	end
	if type(cost) ~= 'string' then
		return _fail(reason, 'invalid-amount', tx)
	end
	local sanitizedCost = BigNumber.sanitize(cost)
	if not sanitizedCost then
		return _fail(reason, 'invalid-amount', tx)
	end

	local current = EconomyService.GetMoney(userId)

	-- A zero-cost "spend" is always allowed; it's a no-op
	-- success. Don't bother with the compare.
	if BigNumber.IsZero(sanitizedCost) then
		return _ok(reason, current, tx)
	end

	-- Critical section: compare-then-write. There is no
	-- `task.yield()` between this read and the write below
	-- so a second concurrent call on the same userId from
	-- the same script serializes on the VM.
	local cmp = BigNumber.Compare(current, sanitizedCost)
	if cmp < 0 then
		-- Insufficient funds. Do NOT mutate. The caller
		-- (e.g. EggService.Purchase) bails on
		-- failure and the slot reservation path is the
		-- only cleanup needed.
		return _fail(reason, 'insufficient', tx)
	end

	-- Subtract is clamped to "0" at the BigNumber level —
	-- money is unsigned, and the caller already checked
	-- `current >= sanitizedCost` above so the result is
	-- always non-negative. The AllowNegative opt is
	-- reserved for future flows (e.g. a bank loan) and
	-- would relax the clamp; it has no observable effect
	-- today because Subtract already clamps.
	local newBalance = BigNumber.Subtract(current, sanitizedCost)
	data.Money = newBalance
	-- Root replication: same pipeline as AddMoney above.
	pushMoneyState(userId)
	return _ok(reason, newBalance, tx)
end

return table.freeze(EconomyService)
