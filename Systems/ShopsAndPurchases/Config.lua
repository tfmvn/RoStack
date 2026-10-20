--!strict
--[[
	Shops and Purchases — consolidated tunables
	=============================================

		A documented view of every value the Shops and Purchases
		system reads.

		The authoritative copies live in two modules:
		  * ReplicatedStorage.Config.Economy.Shop  -- the product
		    registry (ids, prices, kinds, payloads, card map)
		  * ReplicatedStorage.Config.Systems.Security -- the
		    receipt and door rate limits
		  * ReplicatedStorage.Config.World.Prompts    -- the
		    door prompt's text, hold duration, and range

		This file is a CONSOLIDATION, not a replacement. Copy any
		value you change back into the module that owns it, or
		uncomment the require block at the bottom to make this file
		the live source of truth.

		NOTE ON THE MODULE NAME: this consolidation is called
		ShopsConfig, NOT ShopConfig. ShopConfig is the alias the
		SERVICES use for ReplicatedStorage.Config.Economy.Shop --
		keep the two apart so you never confuse the live registry
		with this documented view of it.

		NOTE ON THE LAYOUT: this consolidation is FLAT
		(ShopsConfig.MoneyPack1, ShopsConfig.Money2x,
		ShopsConfig.ServerLuckDuration2x), while the live registry
		is NESTED (Shop.DeveloperProducts.MoneyPack1,
		Shop.Gamepasses.Money2x, Shop.ServerLuckDurations[2]).
		The flat layout is a readability choice; the wiring block
		at the bottom maps one to the other.

		WARNING: Shop.lua has NO Validate() function. It is the
		only config in this library without one. The only
		integrity check is a require-time warn() on a duplicate
		ProductId (first entry wins). A malformed product -- a
		missing ProductId, a Money product with no Amount -- is
		only detected at runtime, by a receipt that then retries
		forever.

		WARNING: every ProductId and GamepassId below is a
		PLACEHOLDER for a new game. They are the real ids from
		the source game's Creator Dashboard. Replace all 13 of
		them, or every receipt will be an "unknown ProductId"
		and will retry forever.

		Not owned here:
		  * GearShopService -- the gear catalogue and the Tool
		    assets
		  * DailyRewardsService / PlaytimeRewardsService -- the
		    skip-access semantics
		  * BaseLockService -- the lock state and the per-buyer
		    grant list
		  * ServerLuckService -- the boost itself
	]]

local ShopsConfig = {}

-- =========================================================================
-- Developer Products
-- =========================================================================
--
-- Twelve products. Each is: Key, ProductId, Robux (DISPLAY ONLY),
-- Kind (the dispatch), and the kind-specific payload.

-- The 2X server luck product.
-- Default: ProductId 3715397847, 99 Robux, Multiplier 2.
-- Meaning: a temporary server-wide luck boost at 2x. The DURATION
--   comes from ShopsConfig.ServerLuckDurations[2] (900 seconds) --
--   the product entry never carries a duration.
-- Valid range: a real, non-zero Developer Product id from YOUR
--   Creator Dashboard; a positive integer Multiplier that has an
--   entry in ServerLuckDurations.
-- Safe to change: the ProductId -- YES, but you MUST change it.
--   The Multiplier -- YES, but you must also add a matching
--   ServerLuckDurations entry or the receipt will retry forever
--   ("luck product misconfigured").
-- Read by: ShopService._handleReceipt / _grantLuck; the client
--   Shop buttons (via ShopsConfig.FindProduct).
-- Placeholder: YES -- the ProductId is the source game's real id.
ShopsConfig.ServerLuck2x = {
	Key = 'ServerLuck2x',
	ProductId = 3715397847,
	Robux = 99,
	Kind = 'ServerLuck',
	Multiplier = 2,
}

-- The Unlock Doors product.
-- Default: ProductId 3715397812, 29 Robux.
-- Meaning: buys access to a locked base. Opens the base NOW and
--   records a per-buyer grant that survives a later owner
--   re-lock and clears on base release/reassign.
-- Valid range: a real Developer Product id.
-- Safe to change: YES, but you MUST change it.
-- Read by: ShopService._handleReceipt / _grantUnlockDoors;
--   DoorService.RequestOpen (the product id it prompts with).
-- Placeholder: YES.
ShopsConfig.UnlockDoors = {
	Key = 'UnlockDoors',
	ProductId = 3715397812,
	Robux = 29,
	Kind = 'UnlockDoors',
}

-- The 4X server luck product.
-- Default: ProductId 3715398478, 199 Robux, Multiplier 4.
-- Meaning: a temporary server-wide luck boost at 4x. Duration from
--   ServerLuckDurations[4] (600 seconds).
-- Valid range: as above.
-- Safe to change: as above.
-- Read by: ShopService._grantLuck.
-- Placeholder: YES.
ShopsConfig.ServerLuck4x = {
	Key = 'ServerLuck4x',
	ProductId = 3715398478,
	Robux = 199,
	Kind = 'ServerLuck',
	Multiplier = 4,
}

-- The Galaxy Bat gear product.
-- Default: ProductId 3715398070, 199 Robux, GearId 'GalaxyBat'.
-- Meaning: grants the Galaxy Bat gear and then EQUIPS it
--   (best-effort -- a failed equip does not retry, because the
--   grant already committed).
-- Valid range: a real Developer Product id; a GearId that exists
--   in the gear catalogue AND has a Tool asset in the game.
-- Safe to change: the ProductId -- YES, you MUST change it. The
--   GearId -- only if you have a matching gear entry; the
--   GalaxyBat-specific funnel steps key off the literal string
--   'GalaxyBat'.
-- Read by: ShopService._grantGear; the GalaxyBat funnel steps.
-- Placeholder: YES.
ShopsConfig.GalaxyBat = {
	Key = 'GalaxyBat',
	ProductId = 3715398070,
	Robux = 199,
	Kind = 'Gear',
	GearId = 'GalaxyBat',
}

-- The 8X server luck product.
-- Default: ProductId 3715398723, 499 Robux, Multiplier 8.
-- Meaning: a temporary server-wide luck boost at 8x. Duration from
--   ServerLuckDurations[8] (300 seconds).
-- Valid range: as above.
-- Safe to change: as above.
-- Read by: ShopService._grantLuck.
-- Placeholder: YES.
ShopsConfig.ServerLuck8x = {
	Key = 'ServerLuck8x',
	ProductId = 3715398723,
	Robux = 499,
	Kind = 'ServerLuck',
	Multiplier = 8,
}

-- The five money packs.
-- Default: MoneyPack1 3715397862 / 19 R / '10000'
--         MoneyPack2 3715397884 / 49 R / '50000'
--         MoneyPack3 3715397918 / 99 R / '250000'
--         MoneyPack4 3715397931 / 199 R / '500000'
--         MoneyPack5 3715397968 / 249 R / '1000000'
-- Meaning: a flat money grant. The Amount is the RAW BigNumber
--   decimal string, NOT a preformatted value -- NotificationService
--   owns all {Amount} formatting (_cleanAmount), and a
--   preformatted '$10K' would fail sanitize there and render as
--   '$0'.
-- Valid range: a real Developer Product id; Amount is a
--   non-empty decimal string that BigNumber.sanitize accepts.
-- Safe to change: the ProductIds -- YES, you MUST change them. The
--   Amounts -- YES, freely; they are designer-owned. The config
--   comment flags the ladder as "derived from the live economy
--   ... sane but unapproved -- DESIGNER: confirm these before
--   launch".
-- Read by: ShopService._grantMoney; EconomyService.AddMoney with
--   the reason 'ShopMoneyPack'.
-- Placeholder: YES (the ProductIds).
ShopsConfig.MoneyPack1 = {
	Key = 'MoneyPack1',
	ProductId = 3715397862,
	Robux = 19,
	Kind = 'Money',
	Amount = '10000',
}

ShopsConfig.MoneyPack2 = {
	Key = 'MoneyPack2',
	ProductId = 3715397884,
	Robux = 49,
	Kind = 'Money',
	Amount = '50000',
}

ShopsConfig.MoneyPack3 = {
	Key = 'MoneyPack3',
	ProductId = 3715397918,
	Robux = 99,
	Kind = 'Money',
	Amount = '250000',
}

ShopsConfig.MoneyPack4 = {
	Key = 'MoneyPack4',
	ProductId = 3715397931,
	Robux = 199,
	Kind = 'Money',
	Amount = '500000',
}

ShopsConfig.MoneyPack5 = {
	Key = 'MoneyPack5',
	ProductId = 3715397968,
	Robux = 249,
	Kind = 'Money',
	Amount = '1000000',
}

-- The Skip Playtime product.
-- Default: ProductId 3716261541, 149 Robux.
-- Meaning: grants the playtime-rewards skip access AND then
--   immediately runs the identical gated ClaimAll path. The
--   receipt IS the entitlement -- access is granted first, then
--   claimed.
-- Valid range: a real Developer Product id.
-- Safe to change: YES, but you MUST change it.
-- Read by: ShopService._grantSkipPlaytime.
-- Placeholder: YES.
ShopsConfig.SkipPlaytime = {
	Key = 'SkipPlaytime',
	ProductId = 3716261541,
	Robux = 149,
	Kind = 'SkipPlaytime',
}

-- The Skip Daily product.
-- Default: ProductId 3716261585, 249 Robux.
-- Meaning: grants the daily-rewards skip access AND then runs the
--   identical gated ClaimAll path.
-- Valid range: a real Developer Product id.
-- Safe to change: YES, but you MUST change it.
-- Read by: ShopService._grantSkipDaily.
-- Placeholder: YES.
ShopsConfig.SkipDaily = {
	Key = 'SkipDaily',
	ProductId = 3716261585,
	Robux = 249,
	Kind = 'SkipDaily',
}

-- =========================================================================
-- Gamepasses
-- =========================================================================

-- The 2X Money gamepass.
-- Default: GamepassId 2002490328, 199 Robux.
-- Meaning: a MoneyMultiplier of 2 applied to the owner. The
--   entitlement is re-resolved from
--   MarketplaceService:UserOwnsGamePassAsync on join and on an
--   explicit ShopAction 'SyncGamepass' -- gamepasses emit NO
--   receipts. The ModifierService source id is the literal
--   'Gamepass_2XMoney' and the modifier is SESSION-SCOPED
--   (ModifierService never persists).
-- Valid range: a real, non-zero Gamepass id.
-- Safe to change: YES, but you MUST change it.
-- Read by: ShopService.SyncGamepassAsync; the client gamepass
--   button (via ShopsConfig.Gamepasses.Money2x).
-- Placeholder: YES.
ShopsConfig.Money2x = {
	Key = 'Money2x',
	GamepassId = 2002490328,
	Robux = 199,
}

-- =========================================================================
-- Server luck durations
-- =========================================================================

-- The temporary luck boost duration, in seconds, per multiplier.
-- Default: 2x -> 900, 4x -> 600, 8x -> 300.
-- Meaning: how long the server-wide luck boost lasts for a given
--   multiplier. Higher multipliers last SHORTER.
-- Valid range: a positive number of seconds. Every multiplier used
--   by a ServerLuck product MUST have an entry here -- a missing
--   entry makes the receipt retry forever.
-- Safe to change: YES -- DESIGNER-OWNED. No duration is hardcoded
--   in any service.
-- Read by: ShopService._grantLuck (via
--   ShopsConfig.ServerLuckDurations[mult]).
-- Placeholder: NO -- real, tuned values.
ShopsConfig.ServerLuckDuration2x = 900
ShopsConfig.ServerLuckDuration4x = 600
ShopsConfig.ServerLuckDuration8x = 300

-- =========================================================================
-- Behavioural constants
-- =========================================================================

-- The ModifierService source id for the 2X Money gamepass.
-- Default: 'Gamepass_2XMoney'
-- Meaning: the source identity the multiplier is filed under. The
--   sync handler scans ModifierService.GetModifiers for this
--   exact string to decide "was already owned".
-- Valid range: any unique string.
-- Safe to change: YES -- but change it EVERYWHERE at once: it is
--   hardcoded as a module-local in ShopService.lua
--   (GAMEPASS_2X_SOURCE), not read from the config.
-- Read by: ShopService (hardcoded constant).
-- Placeholder: NO.
ShopsConfig.GamepassSourceId = 'Gamepass_2XMoney'

-- The EconomyService transaction reason for a money pack.
-- Default: 'ShopMoneyPack'
-- Meaning: the audit label written on the money transaction.
-- Valid range: a value in the CLOSED TransactionReason enum.
-- Safe to change: NO -- EconomyService rejects any reason outside
--   the enum's _ALL list with the code 'invalid-reason', and the
--   grant then retries forever.
-- Read by: ShopService._grantMoney (hardcoded literal).
-- Placeholder: NO.
ShopsConfig.MoneyTransactionReason = 'ShopMoneyPack'

-- The ServerLuckService boost source.
-- Default: 'ShopPurchase'
-- Meaning: the source label recorded on the temporary luck boost.
-- Valid range: any string the luck service accepts.
-- Safe to change: YES -- but it is hardcoded in ShopService.lua,
--   not read from the config.
-- Read by: ShopService._grantLuck (hardcoded literal).
-- Placeholder: NO.
ShopsConfig.LuckBoostSource = 'ShopPurchase'

-- The door prompt's instance name.
-- Default: 'OpenDoorPrompt'
-- Meaning: the ProximityPrompt's Name. DoorService finds and
--   creates the prompt by this exact name on the base's collector
--   part. If you rename it, change PROMPT_NAME in DoorService.lua
--   too -- it is hardcoded there.
-- Valid range: any instance name.
-- Safe to change: YES -- but change it in BOTH places.
-- Read by: DoorService (hardcoded constant).
-- Placeholder: NO.
ShopsConfig.DoorPromptName = 'OpenDoorPrompt'

-- =========================================================================
-- Rate limits and caps (authoritative: Security.lua)
-- =========================================================================

-- The receipt dedupe table's cap.
-- Default: 5000
-- Meaning: how many PurchaseIds are remembered before the table is
--   flushed. On overflow the WHOLE table is cleared (table.clear),
--   not just the oldest entry -- it is NOT an LRU. The module
--   accepts the residual risk of an ancient duplicate re-granting.
-- Valid range: a positive integer.
-- Safe to change: YES.
-- Read by: ShopService (Security.Receipts.SeenCap).
-- Placeholder: NO.
ShopsConfig.ReceiptSeenCap = 5000

-- The ShopAction per-player throttle.
-- Default: 5 (seconds)
-- Meaning: how often one player may trigger a gamepass sync. It
--   exists so a dialog-close burst cannot stack expensive
--   UserOwnsGamePassAsync ownership checks.
-- Valid range: a positive number of seconds.
-- Safe to change: YES.
-- Read by: ShopService (Security.Receipts.ActionCooldownSeconds).
-- Placeholder: NO.
ShopsConfig.ShopActionCooldownSeconds = 5

-- The door purchase-request per-player throttle.
-- Default: 5 (seconds)
-- Meaning: one Roblox purchase dialog per player per window. The
--   receipt itself is idempotent -- this only gates dialogs.
-- Valid range: a positive number of seconds.
-- Safe to change: YES.
-- Read by: DoorService (Security.Door.RequestCooldownSeconds).
-- Placeholder: NO.
ShopsConfig.DoorRequestCooldownSeconds = 5

-- The door distance slack.
-- Default: 2 (studs)
-- Meaning: added to PromptConfig.DoorOpen.MaxActivationDistance
--   (12) to give the server-side range check 2 studs of slack for
--   the movement between the client's trigger and the server's
--   check. The effective reach is 14 studs.
-- Valid range: a number >= 0.
-- Safe to change: YES.
-- Read by: DoorService (Security.Door.RangeSlackStuds).
-- Placeholder: NO.
ShopsConfig.DoorRangeSlackStuds = 2

-- The funnel prompt-intent cooldown.
-- Default: 2 (seconds)
-- Meaning: how often one player's 'FunnelPrompt' analytics ping is
--   logged. It is an ANALYTICS throttle, not an entitlement.
-- Valid range: a positive number of seconds.
-- Safe to change: YES.
-- Read by: ShopService (HARDCODED local PROMPT_COOLDOWN_S -- it is
--   NOT in Security.lua, unlike the limits above).
-- Placeholder: NO.
ShopsConfig.PromptCooldownSeconds = 2

-- The pending door purchase context's TTL.
-- Default: 900 (15 minutes)
-- Meaning: how long a pending door purchase context survives
--   before it is swept. It exists so a buyer who disconnects
--   mid-dialog and rejoins still fulfills when the receipt retries.
--   Older contexts are dropped, and the receipt then consumes
--   loudly instead of unlocking a long-gone situation.
-- Valid range: a positive number of seconds.
-- Safe to change: YES.
-- Read by: DoorService (HARDCODED local PENDING_TTL_S -- it is
--   NOT in Security.lua, unlike the limits above).
-- Placeholder: NO.
ShopsConfig.DoorPendingTtlSeconds = 900

-- =========================================================================
-- Door prompt presentation (authoritative: Prompts.lua)
-- =========================================================================

-- The prompt's action text.
-- Default: 'Open Door'
-- Meaning: the button label on the ProximityPrompt.
-- Valid range: any string.
-- Safe to change: YES.
-- Read by: DoorService.RefreshBase (PromptConfig.DoorOpen).
-- Placeholder: NO.
ShopsConfig.DoorActionText = 'Open Door'

-- The prompt's object text.
-- Default: 'Locked Base'
-- Meaning: the secondary line on the ProximityPrompt.
-- Valid range: any string.
-- Safe to change: YES.
-- Read by: DoorService.RefreshBase.
-- Placeholder: NO.
ShopsConfig.DoorObjectText = 'Locked Base'

-- The prompt's hold duration.
-- Default: 0 (seconds)
-- Meaning: how long the player must hold to trigger. 0 = a tap.
-- Valid range: a number >= 0.
-- Safe to change: YES.
-- Read by: DoorService.RefreshBase.
-- Placeholder: NO.
ShopsConfig.DoorHoldDuration = 0

-- The prompt's activation distance.
-- Default: 12 (studs)
-- Meaning: the client-side trigger range. The SERVER check uses
--   this PLUS DoorRangeSlackStuds (2) = 14 studs effective.
-- Valid range: a positive number of studs.
-- Safe to change: YES.
-- Read by: DoorService.RefreshBase (MaxActivationDistance) and
--   DoorService.RequestOpen (the range check).
-- Placeholder: NO.
ShopsConfig.DoorMaxActivationDistance = 12

-- The prompt's line-of-sight requirement.
-- Default: false
-- Meaning: whether the player needs line of sight to the collector.
-- Valid range: a boolean.
-- Safe to change: YES -- but note the SERVER re-check measures
--   the raw distance and does not check line of sight, so turning
--   this on makes the client stricter than the server.
-- Read by: DoorService.RefreshBase (RequiresLineOfSight).
-- Placeholder: NO.
ShopsConfig.DoorRequiresLineOfSight = false

-- =========================================================================
-- Derived (not configurable -- documented so the numbers make sense)
-- =========================================================================
--
-- The receipt decision table:
--   malformed info                  -> PurchaseGranted  (break the loop)
--   duplicate PurchaseId            -> PurchaseGranted  (already done)
--   unknown ProductId               -> NotProcessedYet  (fix the config)
--   buyer gone, player-bound kind   -> NotProcessedYet  (retry after rejoin)
--   buyer gone, ServerLuck kind     -> PurchaseGranted  (server-wide)
--   grant helper returned 'retry'   -> NotProcessedYet
--   grant helper returned 'granted' -> PurchaseGranted
--
-- The door grant decision table (all of these CONSUME the receipt,
-- i.e. return true; only an internal error returns false):
--   no pending context               -> consume, warn, toast
--   base gone                        -> consume, warn, toast
--   base raced open, same owner      -> GRANT RECORDED, toast (no unlock)
--   base raced open, different owner -> consume, warn, toast
--   ownership changed                -> consume, warn, toast
--   buyer is now the owner           -> consume, warn, toast
--   the happy path                   -> unlock + record, toast
--
-- INVARIANT: the dedupe write happens ONLY on the granted branch, so
-- a failed grant stays retryable.
--
-- INVARIANT: the pending door context is consumed on READ, before
-- the grant is evaluated, so a repeat receipt cannot re-grant. The
-- grant itself is idempotent inside BaseLockService.
--
-- INVARIANT: the door grant NEVER trusts the stored context. It
-- re-resolves the current owner, the current lock state, and the
-- buyer's current relationship to the base.

-- =========================================================================
-- Optional: wire this file to the authoritative modules
-- =========================================================================
--
-- Uncomment to make this consolidation the live source of truth. The
-- defaults above are the current live values, so switching over is a
-- no-op until you edit something.
--
-- NOTE: Shop.lua has no Validate(); if you wire this file to it,
-- keep the ids in sync or every receipt will retry forever.

-- local Shop = require(game:GetService('ReplicatedStorage').Config.Economy.Shop)
-- local Security = require(game:GetService('ReplicatedStorage').Config.Systems.Security)
-- local Prompts = require(game:GetService('ReplicatedStorage').Config.World.Prompts)
-- for key, entry in pairs(Shop.DeveloperProducts) do
-- 	ShopsConfig[key] = entry
-- end
-- ShopsConfig.Money2x = Shop.Gamepasses.Money2x
-- ShopsConfig.ServerLuckDuration2x = Shop.ServerLuckDurations[2]
-- ShopsConfig.ServerLuckDuration4x = Shop.ServerLuckDurations[4]
-- ShopsConfig.ServerLuckDuration8x = Shop.ServerLuckDurations[8]
-- ShopsConfig.ReceiptSeenCap = Security.Receipts.SeenCap
-- ShopsConfig.ShopActionCooldownSeconds = Security.Receipts.ActionCooldownSeconds
-- ShopsConfig.DoorRequestCooldownSeconds = Security.Door.RequestCooldownSeconds
-- ShopsConfig.DoorRangeSlackStuds = Security.Door.RangeSlackStuds
-- ShopsConfig.DoorActionText = Prompts.DoorOpen.ActionText
-- ShopsConfig.DoorObjectText = Prompts.DoorOpen.ObjectText
-- ShopsConfig.DoorHoldDuration = Prompts.DoorOpen.HoldDuration
-- ShopsConfig.DoorMaxActivationDistance = Prompts.DoorOpen.MaxActivationDistance
-- ShopsConfig.DoorRequiresLineOfSight = Prompts.DoorOpen.RequiresLineOfSight

return table.freeze(ShopsConfig)
