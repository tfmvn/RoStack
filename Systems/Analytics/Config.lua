--!strict
--[[
	Analytics — consolidated tunables
	==================================
	A read-only, commented copy of the tunables that live as
	literals inside `ServerScriptService/FunnelService.lua`.

	This file does NOT change the behaviour of the running game:
	`FunnelService` does not require it. It exists so a new game can
	see every knob in one place and copy the values it wants to
	change into its own `FunnelService.lua`.

	When you fork the system, edit the literals in
	`FunnelService.lua` directly (and mirror them here), or replace
	this module with a real config and change the requires in
	`FunnelService.lua` to point at it.
]]

local AnalyticsConfig = {}

-- ---------------------------------------------------------------------------
-- Funnel plan
-- ---------------------------------------------------------------------------

-- The canonical funnel plan.
--
-- DEFAULT: the 12 funnels shipped with Brainrot Arena.
-- MEANING: for each funnel, the ordered list of step names a player
--   passes through. The **1-based index of a step name inside its
--   array IS the Roblox funnel step number**. Roblox keys funnel
--   telemetry on (funnelName, stepNumber), so the order is
--   load-bearing: reordering an array renumbers every event in that
--   funnel, and the Creator Hub dashboard must be built to match
--   exactly or the events will not attribute.
-- VALID RANGE: any number of steps, but keep the array stable after
--   launch. Adding a step in the middle shifts all later steps.
-- SAFE TO CHANGE: yes, before launch and while the dashboard is
--   still editable. No, after launch — you would need a new funnel
--   name to avoid re-numbering live events.
-- READ BY: `FunnelService._stepNumber` (step lookup) and
--   `_defaultSend` (the `Onboarding` special case).
-- PLACEHOLDER: no — these are the real product funnels. Replace the
--   whole table for a new game.
AnalyticsConfig.Funnels = {
	Onboarding = {
		'TutorialStarted',
		'FirstEggPurchased',
		'FirstEggHatched',
		'FirstAnimalPlaced',
		'FirstArenaStarted',
		'FirstArenaCompleted',
		'TutorialCompleted',
		'TutorialSkipped',
	},
	Progression = {
		'FirstEggPurchased',
		'FirstAnimalUpgraded',
		'FirstRebirth',
	},
	Upgrade = {
		'FirstAnimalUpgraded',
		'UpgradeSucceeded',
	},
	Rebirth = {
		'RebirthAttempted',
		'RebirthRequirementReached',
		'RebirthSucceeded',
	},
	Arena = {
		'ArenaStarted',
		'StageProgressed',
		'ArenaCompleted',
	},
	Monetization = {
		'ShopItemPrompted',
		'PurchaseConfirmed',
		'ItemGranted',
	},
	GalaxyBat = {
		'GalaxyBatPrompted',
		'GalaxyBatReceiptConfirmed',
		'GalaxyBatGranted',
		'GalaxyBatEquipped',
	},
	Gear = {
		'FirstGearPurchased',
		'FirstGearEquipped',
	},
	Gamepass = {
		'GamepassPrompted',
		'GamepassSynced',
	},
	Event = {
		'EventParticipated',
		'MutationReceived',
	},
	Rewards = {
		'DailyRewardClaimed',
		'PlaytimeRewardClaimed',
		'CodeRedeemed',
	},
	Social = {
		'StealSucceeded',
		'FirstBaseLocked',
	},
}

-- One-time-per-session milestones.
--
-- DEFAULT: the 16 entries below.
-- MEANING: a `"<funnel>/<step>"` key here makes that step fire at
--   most once per player per session. Repeat calls are silently
--   dropped (but `LogStep` still returns `true`).
-- VALID RANGE: any subset of the funnel plan.
-- SAFE TO CHANGE: yes. Removing an entry makes the step repeat.
-- READ BY: `FunnelService.LogStep` (dedupe key selection).
-- PLACEHOLDER: no.
AnalyticsConfig.ONCE = {
	['Onboarding/TutorialStarted'] = true,
	['Onboarding/FirstEggPurchased'] = true,
	['Onboarding/FirstEggHatched'] = true,
	['Onboarding/FirstAnimalPlaced'] = true,
	['Onboarding/FirstArenaStarted'] = true,
	['Onboarding/FirstArenaCompleted'] = true,
	['Onboarding/TutorialCompleted'] = true,
	['Onboarding/TutorialSkipped'] = true,
	['Progression/FirstEggPurchased'] = true,
	['Progression/FirstAnimalUpgraded'] = true,
	['Progression/FirstRebirth'] = true,
	['Upgrade/FirstAnimalUpgraded'] = true,
	['Gear/FirstGearPurchased'] = true,
	['Gear/FirstGearEquipped'] = true,
	['Social/FirstBaseLocked'] = true,
	['Gamepass/GamepassSynced'] = true,
}

-- Scoped (once per session per `metadata._key`) milestones.
--
-- DEFAULT: the 10 entries below.
-- MEANING: a `"<funnel>/<step>"` key here makes that step fire at
--   most once per session **per `metadata._key`**. Callers MUST pass
--   `_key` (e.g. the rebirth number, the purchase id, the arena
--   stage). Without `_key` the step fires on every call — safe, but
--   noisy.
-- VALID RANGE: any subset of the funnel plan.
-- SAFE TO CHANGE: yes.
-- READ BY: `FunnelService.LogStep` (dedupe key selection).
-- PLACEHOLDER: no.
AnalyticsConfig.SCOPED = {
	['Rebirth/RebirthRequirementReached'] = true,
	['Rebirth/RebirthAttempted'] = true,
	['Rebirth/RebirthSucceeded'] = true,
	['Arena/StageProgressed'] = true,
	['Monetization/PurchaseConfirmed'] = true,
	['Monetization/ItemGranted'] = true,
	['GalaxyBat/GalaxyBatReceiptConfirmed'] = true,
	['GalaxyBat/GalaxyBatGranted'] = true,
	['GalaxyBat/GalaxyBatEquipped'] = true,
	['Event/EventParticipated'] = true,
}

-- Arena stages worth a funnel event.
--
-- DEFAULT: `{1, 5, 10, 25, 50}`.
-- MEANING: the game has 50 arena stages; emitting an event for every
--   stage win would be noise, so only these milestones emit.
-- VALID RANGE: any set of positive integers <= the arena stage cap.
-- SAFE TO CHANGE: yes.
-- READ BY: `FunnelService.IsArenaMilestone`.
-- PLACEHOLDER: no.
AnalyticsConfig.ArenaMilestones = { 1, 5, 10, 25, 50 }

-- Maximum number of recorded calls kept in the in-memory diagnostic
-- buffer.
--
-- DEFAULT: 1000.
-- MEANING: `_calls` is a diagnostic/test buffer, not a log. Once it
--   reaches the cap, further calls are still SENT and still deduped
--   — they are simply not recorded.
-- VALID RANGE: 0 .. large. `0` disables recording entirely.
-- SAFE TO CHANGE: yes.
-- READ BY: `FunnelService.LogStep` (recording), `_TestGetCalls`.
-- PLACEHOLDER: no.
AnalyticsConfig.CallsCap = 1000

-- Master switch.
--
-- DEFAULT: true.
-- MEANING: when false, `LogStep` is a no-op that returns `false` and
--   sends nothing. Only `_TestSetEnabled` flips it at runtime.
-- VALID RANGE: boolean.
-- SAFE TO CHANGE: yes.
-- READ BY: `FunnelService.LogStep`.
-- PLACEHOLDER: no.
AnalyticsConfig.Enabled = true

-- Level buckets used for upgrade metadata.
--
-- DEFAULT: `{ '1-10', '11-25', '26-50', '51-100', '100+' }`.
-- MEANING: coarse level bands keep metadata cardinality bounded.
--   The last band is the catch-all for anything above the second-to-
--   last threshold.
-- VALID RANGE: any ordered list of band labels.
-- SAFE TO CHANGE: yes, but the labels are what the analytics
--   dashboard groups by.
-- READ BY: `FunnelService.LevelBand`.
-- PLACEHOLDER: no.
AnalyticsConfig.LevelBands = {
	{ Max = 10, Label = '1-10' },
	{ Max = 25, Label = '11-25' },
	{ Max = 50, Label = '26-50' },
	{ Max = 100, Label = '51-100' },
	{ Max = math.huge, Label = '100+' },
}

return table.freeze(AnalyticsConfig)
