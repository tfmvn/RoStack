--!strict
--[[
	TransactionReason
	=================
	Closed set of audit-trail reasons attached to every Money
	mutation in EconomyService.

	Why a closed enum:
	  * A grant for "this player bought a lucky egg" must
	    be auditable as a EggPurchase, not a free-form
	    string.
	  * The Debug log line includes the reason so we can read
	    back why a player's Money went from $1.2M to $0.
	  * Rejecting unknown reasons at the service boundary
	    means a typo in a Cmdr command can't silently change
	    a player's Money.

	The enum is the *only* set the service accepts. Adding a
	reason here is a deliberate change to the audit taxonomy.

	Wire format: the table values are the canonical strings
	that appear in Debug.Log lines. They are stable forever.
]]

local TransactionReason = {
	-- Seeding the player's wallet for the very first time
	-- after the reconcile pass in PlayerService.LoadPlayerData.
	StartingMoney = 'StartingMoney',

	-- An Egg was successfully purchased from the shop
	-- prompt. The corresponding TrySpendMoney debit uses
	-- this reason; any refund uses one of the *Refund
	-- reasons below.
	EggPurchase = 'EggPurchase',

	-- An Egg that was purchased is being refunded
	-- (e.g. flight was force-released mid-air, slot race
	-- failed before commit, etc).
	EggRefund = 'EggRefund',

	-- An Egg that was opened by a player (the roll
	-- consumed it) is being refunded. Reserved for future
	-- "re-roll on bad luck" flows; not currently emitted
	-- but listed in the taxonomy so a future system can
	-- adopt it without changing the service.
	EggOpenRefund = 'EggOpenRefund',

	-- An admin /setmoney call set the player's balance to
	-- an absolute value (delta-derive path, then one
	-- AddMoney of the difference).
	AdminSet = 'AdminSet',

	-- An admin /givemoney call incremented the player's
	-- balance by a positive amount.
	AdminGive = 'AdminGive',

	-- A player touched a slot's CashCollector and the cash that
	-- had accumulated in that slot's CashPool transferred into
	-- their Money (Phase 2.6). This is a TRANSFER, not a grant:
	-- the amount was already shaped when it accumulated into the
	-- pool, so the caller passes {ApplyMultiplier = false} — the
	-- Money multiplier must never apply twice.
	CashCollector = 'CashCollector',

	-- A player sold an owned Animal (Phase 2.8). The payout is
	-- the level-adjusted sell value PLUS the animal's current
	-- CashPool, transferred atomically: the pool is consumed
	-- under IncomeService's claim lock before this grant, so the
	-- caller passes {ApplyMultiplier = false} and the pool can
	-- never pay twice (sale vs. collection race).
	SellAnimal = 'SellAnimal',

	-- A player sold an owned Egg (Phase 2.8): the egg's
	-- authoritative rarity price, no level scaling, no CashPool
	-- (eggs never earn). Same {ApplyMultiplier = false} rule —
	-- the Money multiplier is for online passive income only.
	SellEgg = 'SellEgg',

	-- A player bought an Animal level upgrade (Phase 2.10):
	-- Level += 1 for the authoritative upgrade cost, debited
	-- atomically via TrySpendMoney. XP, CashPool, slot, and
	-- identity are untouched; multipliers never shape the cost.
	AnimalUpgrade = 'AnimalUpgrade',

	-- A player bought Gear Shop gear: debited atomically via
	-- TrySpendMoney for the authoritative GearConfig price.
	-- Covers manual buys and AutoBuy grants (same debit path).
	GearPurchase = 'GearPurchase',

	-- A Gear Shop debit is being refunded because the Tool
	-- grant could not be verified in Backpack/Character
	-- after the debit landed (grant-failed rollback).
	GearRefund = 'GearRefund',

	-- An Arena expedition completion grant: first-clear or
	-- repeat cash awarded once per won battle through the
	-- canonical EconomyService grant path.
	ArenaReward = 'ArenaReward',

	-- A player bought an Arena paid restart (authored Main.Arena
	-- Buy1/Buy2): debited atomically via TrySpendMoney for the
	-- authoritative ArenaConfig restart price before the raid
	-- starts at the authorized stage.
	ArenaRestart = 'ArenaRestart',

	-- An Arena restart debit is being refunded because the raid
	-- failed to start after the debit landed (grant-failed
	-- rollback, same pattern as GearRefund).
	ArenaRestartRefund = 'ArenaRestartRefund',

	-- A redeem-code reward grant: cash awarded once per code
	-- redemption through the canonical EconomyService grant
	-- path (CodesService owns validation + redemption state).
	CodeReward = 'CodeReward',

	-- A Robux Shop money-pack grant through the canonical
	-- EconomyService grant path (ShopService receipt owns
	-- validation + idempotency).
	ShopMoneyPack = 'ShopMoneyPack',
}

-- Canonical list. The service iterates this to validate
-- reasons without hard-coding the set twice. Order matches
-- the table above; do not reorder without a real reason.
local _ALL = {
	TransactionReason.StartingMoney,
	TransactionReason.EggPurchase,
	TransactionReason.EggRefund,
	TransactionReason.EggOpenRefund,
	TransactionReason.AdminSet,
	TransactionReason.AdminGive,
	TransactionReason.CashCollector,
	TransactionReason.SellAnimal,
	TransactionReason.SellEgg,
	TransactionReason.AnimalUpgrade,
	TransactionReason.GearPurchase,
	TransactionReason.GearRefund,
	TransactionReason.ArenaReward,
	TransactionReason.ArenaRestart,
	TransactionReason.ArenaRestartRefund,
	TransactionReason.CodeReward,
	TransactionReason.ShopMoneyPack,
}

-- Predicate: is `value` a known reason string?
function TransactionReason.isValid(value: any): boolean
	if type(value) ~= 'string' then
		return false
	end
	for _, r in ipairs(_ALL) do
		if r == value then
			return true
		end
	end
	return false
end

-- The closed set, for callers that need to enumerate.
TransactionReason.All = table.freeze(_ALL)

return table.freeze(TransactionReason)
