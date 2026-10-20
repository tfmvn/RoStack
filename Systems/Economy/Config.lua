--!strict
--[[
	Economy — consolidated tunables
	================================

	A single, documented view of every value the Economy system
	reads. The authoritative copies live in the two config modules
	below; this file is a CONSOLIDATION, not a replacement. Copy
	any value you change back into the module that owns it, or
	replace the two `require` calls at the bottom with your own
	modules and delete the local copies.

	Owning modules (the authoritative source of truth):
	  * ReplicatedStorage.Config.Economy.Money  -- economy tunables
	  * ReplicatedStorage.Config.Economy.Sell   -- sell-preview look

	Not owned here (owned elsewhere, referenced only):
	  * Animals.SellBaseValue / Animals.SellMultiplier -- price ladder
	  * Traits.SellMultiplierFor / Mutations.SellFold   -- sell factors
	  * AnimalConfig.Stats.Income.Base                 -- income ladder
	  * Progression.XP.GrowthRate                      -- shared 1.12 curve

	Every value below carries: default, meaning, valid range,
	whether it is safe to change, which module reads it, and
	whether it is a placeholder.
]]

local EconomyConfig = {}

-- =========================================================================
-- Wallet
-- =========================================================================

-- Currency granted on first join. String-backed BigNumber.
-- Default: '5000'
-- Meaning: the wallet seed for a brand-new profile. 5,000 buys the first
--   eggs plus the first upgrades immediately, so the opening minutes are
--   action rather than waiting.
-- Valid range: any BigNumber decimal string ('0' or more). No signs.
-- Safe to change: YES -- affects new players only. Never touches an
--   existing balance. Raising it past ~6 figures skips the early game
--   entirely, so re-solve early progression first.
-- Read by: ReplicatedStorage.Config.Economy.Money (authoritative),
--   PlayerService.LoadPlayerData (the reconcile pass seeds from it).
-- Placeholder: NO -- a real, tuned value.
EconomyConfig.StartingMoney = '5000'

-- Per-player wallet ceiling. String-backed BigNumber.
-- Default: '1000000000000000' (10^15)
-- Meaning: the anti-exploit clamp. Any grant that would push the balance
--   above this is clamped and the result carries Code = 'cap-exceeded'
--   (still a success -- the player got what they were granted).
-- Valid range: any BigNumber decimal string >= StartingMoney.
-- Safe to change: YES, but LOWERING it does not take money away -- it
--   only clamps future grants. Existing balances above the new cap stay.
-- Read by: ReplicatedStorage.Config.Economy.Money (authoritative),
--   EconomyService.AddMoney.
-- Placeholder: NO.
EconomyConfig.MaxMoney = '1000000000000000'

-- =========================================================================
-- Income tick
-- =========================================================================

-- Seconds between IncomeService accumulation ticks.
-- Default: 1
-- Meaning: the GRANULARITY of pool growth, not the rate. The tick uses a
--   monotonic os.clock() delta, so a slow server still credits the exact
--   real elapsed time; this only decides how often that happens.
-- Valid range: > 0 (seconds). Numbers.
-- Safe to change: YES. Increase = choppier growth, fewer wakeups.
--   Decrease = smoother growth, more wakeups. Never changes the per-second
--   RATE (that is owned by the animal stats).
-- Read by: ReplicatedStorage.Config.Economy.Money (authoritative),
--   IncomeService.Start (the task.spawn loop).
-- Placeholder: NO.
EconomyConfig.IncomeTickSeconds = 1

-- Maximum offline earnings window, in seconds.
-- Default: 3 * 60 * 60 (10800 = 3 hours)
-- Meaning: offline time beyond this window is simply not paid. Applied
--   per-Animal into its CashPool at rejoin.
-- Valid range: >= 0 (seconds). 0 disables offline earnings entirely.
-- Safe to change: YES -- this is the single biggest lever on how much
--   returning is worth.
-- Read by: ReplicatedStorage.Config.Economy.Money (authoritative),
--   IncomeService.ApplyOfflineEarnings.
-- Placeholder: NO.
EconomyConfig.MaxOfflineSeconds = 3 * 60 * 60

-- Offline effectiveness: the fraction of the live wallet multiplier
-- applied to offline earnings.
-- Default: 0.5
-- Meaning: offline earns rate x moneyMult x effectiveness, so offline is
--   roughly 50% of equivalent online income -- useful for returning
--   players, never a replacement for active play. Fractional remainders
--   are still floored per animal.
-- Valid range: 0..1 inclusive. Numbers.
-- Safe to change: YES. 0 = offline pays time but no multiplier;
--   1 = offline earns exactly like online.
-- Read by: ReplicatedStorage.Config.Economy.Money (authoritative),
--   IncomeService.ApplyOfflineEarnings.
-- Placeholder: NO.
EconomyConfig.OfflineEffectiveness = 0.5

-- How often the income tick refreshes the player's LastSeen stamp while
-- online.
-- Default: 60 (seconds)
-- Meaning: bounds staleness after a server crash -- the worst case is
--   losing at most this much offline credit.
-- Valid range: > 0 (seconds).
-- Safe to change: YES. Smaller = more accurate crash recovery, more
--   profile writes.
-- Read by: ReplicatedStorage.Config.Economy.Money (authoritative),
--   IncomeService._tickPlayer.
-- Placeholder: NO.
EconomyConfig.OfflineHeartbeatSeconds = 60

-- =========================================================================
-- Collection
-- =========================================================================

-- Minimum seconds between successful CashCollector touches by the same
-- player.
-- Default: 0.25
-- Meaning: a multi-body-part touch lands in the same instant; this
--   debounce collapses those into one collection. GAMEPLAY-ADJACENT
--   (feel), NOT a security boundary.
-- Valid range: >= 0 (seconds).
-- Safe to change: YES -- it is a feel knob.
-- Read by: ReplicatedStorage.Config.Economy.Money (authoritative),
--   IncomeService.TryCollect.
-- Placeholder: NO.
EconomyConfig.CollectorDebounceSeconds = 0.25

-- Minimum seconds between replicated CashPool attribute updates on a
-- collector part.
-- Default: 1
-- Meaning: display-only throttle. Accumulation still runs on the income
--   tick with real-elapsed math; collection and offline application force
--   an immediate publish regardless.
-- Valid range: >= 0 (seconds).
-- Safe to change: YES -- presentation only.
-- Read by: ReplicatedStorage.Config.Economy.Money (authoritative),
--   IncomeService._sweepPublish.
-- Placeholder: NO.
EconomyConfig.CashPoolAttributeThrottleSeconds = 1

-- =========================================================================
-- Sell confirmation presentation
-- =========================================================================
--
-- The values below are READ by the client-side sell-confirmation
-- controller, not by SellService. They are the canonical live values
-- (the forked controller locals were reconciled into this module).

-- Stage origin of the preview clone: position + yaw. The authored
-- Orientation pitch is deliberately NOT applied (it would tip the animal
-- face-down).
-- Default: Vector3.new(20.263, 120.066, 20.066) / Vector3.new(0, -31.716, 0)
-- Meaning: where the preview clone is placed in the viewport.
-- Valid range: any Vector3.
-- Safe to change: YES -- presentation only.
-- Read by: ReplicatedStorage.Config.Economy.Sell (authoritative), the
--   client confirmation controller.
-- Placeholder: NO -- tuned to the live framing.
EconomyConfig.SellViewportOriginPosition = Vector3.new(20.263, 120.066, 20.066)
EconomyConfig.SellViewportOriginOrientationDeg = Vector3.new(0, -31.716, 0)

-- Preview clone render scale, about its bbox centre.
-- Default: 1.25
-- Meaning: the viewport renders the animal 1.25x. The live animal keeps
--   exact scale.
-- Valid range: > 0.
-- Safe to change: YES -- viewport only.
-- Read by: ReplicatedStorage.Config.Economy.Sell (authoritative).
-- Placeholder: NO.
EconomyConfig.SellPreviewScale = 1.25

-- Fit margin for the preview frame.
-- Default: 1.1
-- Meaning: bbox corners may approach the frame edges while face centres
--   stay inside. The AnimalViewport path reads this.
-- Valid range: >= 1.0. 1.15 loosens the framing; below 1.0 reintroduces
--   loose framing.
-- Safe to change: YES -- presentation only.
-- Read by: ReplicatedStorage.Config.Economy.Sell (authoritative).
-- Placeholder: NO.
EconomyConfig.SellShowcaseMargin = 1.1

-- Preview zoom factor.
-- Default: 0.7
-- Meaning: camera zoom inside the preview viewport.
-- Valid range: > 0.
-- Safe to change: YES -- presentation only.
-- Read by: ReplicatedStorage.Config.Economy.Sell (authoritative).
-- Placeholder: NO.
EconomyConfig.SellShowcaseZoom = 0.7

-- Camera yaw off the model's facing, in degrees.
-- Default: 25
-- Meaning: a mid-side front-profile close-up (face + one side, upright).
-- Valid range: any number.
-- Safe to change: YES -- presentation only.
-- Read by: ReplicatedStorage.Config.Economy.Sell (authoritative).
-- Placeholder: NO.
EconomyConfig.SellShowcaseYawDeg = 25

-- View-axis lift to near eye level.
-- Default: 0.12
-- Meaning: how far the camera is lifted toward eye level.
-- Valid range: any number.
-- Safe to change: YES -- presentation only.
-- Read by: ReplicatedStorage.Config.Economy.Sell (authoritative).
-- Placeholder: NO.
EconomyConfig.SellShowcaseElevation = 0.12

-- Look-target lift as a fraction of the bbox height.
-- Default: 0.10
-- Meaning: focuses on the face while still enclosing the full bounds.
-- Valid range: 0..1.
-- Safe to change: YES -- presentation only.
-- Read by: ReplicatedStorage.Config.Economy.Sell (authoritative).
-- Placeholder: NO.
EconomyConfig.SellTargetLiftFrac = 0.10

-- Near-plane headroom, as a fraction of the bbox radius, plus an absolute
-- floor so small animals still frame close-up.
-- Default: 0.08 / 0.12
-- Meaning: the minimum clearance kept between the model and the near
--   plane.
-- Valid range: >= 0 for both.
-- Safe to change: YES -- presentation only.
-- Read by: ReplicatedStorage.Config.Economy.Sell (authoritative).
-- Placeholder: NO.
EconomyConfig.SellHeadroomFrac = 0.08
EconomyConfig.SellHeadroomMin = 0.12

-- Floor against degenerate/empty bounds.
-- Default: 0.3 (studs)
-- Meaning: the minimum camera distance.
-- Valid range: >= 0.
-- Safe to change: YES -- presentation only.
-- Read by: ReplicatedStorage.Config.Economy.Sell (authoritative).
-- Placeholder: NO.
EconomyConfig.SellMinDistance = 0.3

-- Rarity-gradient shading: lerp toward white for the first stop, scale
-- toward black for the last.
-- Default: 0.45 / 0.55
-- Meaning: the shading applied across the rarity colour ramp.
-- Valid range: >= 0 for both.
-- Safe to change: YES -- presentation only.
-- Read by: ReplicatedStorage.Config.Economy.Sell (authoritative).
-- Placeholder: NO.
EconomyConfig.SellRarityGradientLightenT = 0.45
EconomyConfig.SellRarityGradientDarkenT = 0.55

-- Preview result timeout, in seconds.
-- Default: 8
-- Meaning: a pending preview that never resolves cleans itself up after
--   this. A safety net, not gameplay.
-- Valid range: > 0.
-- Safe to change: YES.
-- Read by: ReplicatedStorage.Config.Economy.Sell (authoritative).
-- Placeholder: NO.
EconomyConfig.SellResultTimeout = 8

-- Player-facing labels for the confirmation screen.
-- Defaults: 'Sell for $', 'None', 'Lv. ?', 'N/A', '?'
-- Meaning: the strings shown on the sell confirmation.
-- Valid range: any string.
-- Safe to change: YES -- player-facing text only.
-- Read by: ReplicatedStorage.Config.Economy.Sell (authoritative).
-- Placeholder: NO.
EconomyConfig.SellForPrefix = 'Sell for $'
EconomyConfig.SellNoMutations = 'None'
EconomyConfig.SellLevelUnknown = 'Lv. ?'
EconomyConfig.SellLevelNotApplicable = 'N/A'
EconomyConfig.SellRarityUnknown = '?'

-- =========================================================================
-- Derived (not configurable -- documented so the numbers make sense)
-- =========================================================================
--
-- The sell formula is:
--   payout = Animals.SellBaseValue[rarity]
--          x level
--          x Animals.SellMultiplier[rarity]   (uniformly '0.75')
--          x Traits.SellMultiplierFor(trait)
--          x Mutations.SellFold(mutations)
--   plus the animal's CashPool.
--
-- The upgrade formula is:
--   cost = Animals.SellBaseValue[rarity] x 1.12^(level-1)
-- with 1.12 taken from Progression.XP.GrowthRate and computed with exact
-- 28/25 integer arithmetic (see UpgradeService).
--
-- INVARIANT: Animals.SellBaseValue[rarity] MUST equal
-- EggConfig.Price[rarity] for every rarity. A Level-1 animal
-- liquidates for 75% of its egg cost, so hatch-and-sell can never print
-- money. Retune the price table, sell bases, sell factor, trait-sell,
-- mutation-sell, and hatch weights TOGETHER or the recovery band breaks
-- silently. This invariant is owned by
-- ReplicatedStorage.Config.Economy.Money, not by this file.

-- =========================================================================
-- Optional: wire this file to the authoritative modules
-- =========================================================================
--
-- Uncomment to make this consolidation the live source of truth. The
-- defaults above are the current live values, so switching over is a
-- no-op until you edit something.

-- local Money = require(game:GetService('ReplicatedStorage').Config.Economy.Money)
-- local Sell = require(game:GetService('ReplicatedStorage').Config.Economy.Sell)
-- EconomyConfig.StartingMoney = Money.StartingMoney
-- EconomyConfig.MaxMoney = Money.MaxMoney
-- EconomyConfig.IncomeTickSeconds = Money.IncomeTickSeconds
-- EconomyConfig.MaxOfflineSeconds = Money.MaxOfflineSeconds
-- EconomyConfig.OfflineEffectiveness = Money.OfflineEffectiveness
-- EconomyConfig.OfflineHeartbeatSeconds = Money.OfflineHeartbeatSeconds
-- EconomyConfig.CollectorDebounceSeconds = Money.CollectorDebounceSeconds
-- EconomyConfig.CashPoolAttributeThrottleSeconds = Money.CashPoolAttributeThrottleSeconds

return table.freeze(EconomyConfig)
