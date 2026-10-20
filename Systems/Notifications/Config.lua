--!strict
--[[
	Notifications — consolidated tunables
	=======================================
	A read-only, commented copy of every tunable the notification
	system exposes.

	This file does NOT change the behaviour of the running game:
	`NotificationService` does not require it. The service's tunables
	are literals inside
	`ServerScriptService/Base/NotificationService.lua`, and the message
	copy lives in
	`ReplicatedStorage/Config/Presentation/Messages.lua`.

	It exists so a new game can see every knob in one place and copy
	the values it wants to change into its own copy of the service.

	When you fork the system, edit the literals in
	`NotificationService.lua` directly (and mirror them here), or
	replace this module with a real config and change the requires in
	`NotificationService.lua` to point at it.
]]

local NotificationConfig = {}

-- ---------------------------------------------------------------------------
-- Wire categories
-- ---------------------------------------------------------------------------

-- The category string sent to the client for a rejected action.
--
-- DEFAULT: 'Warning'.
-- MEANING: the first argument of
--   `PlayerService.Notify(player, category, text)`. The client
--   (`ToastController`) maps it to a colour/animation: 'Warning' is
--   amber, 'Reward' is green.
-- VALID RANGE: any string, but the client must recognise it.
-- SAFE TO CHANGE: no, unless you also change the client renderer.
-- READ BY: `NotificationService.NotifyWarning` (via the local
--   `WARNING_CATEGORY` literal at line 94).
-- PLACEHOLDER: no.
NotificationConfig.WarningCategory = 'Warning'

-- The category string sent to the client for a committed action.
--
-- DEFAULT: 'Reward'.
-- MEANING: same as above, for successes. Note the name is 'Reward',
--   not 'Success' — the client treats it as a reward toast.
-- VALID RANGE: any string the client recognises.
-- SAFE TO CHANGE: no, unless you also change the client renderer.
-- READ BY: `NotificationService.NotifySuccess` (via the local
--   `SUCCESS_CATEGORY` literal at line 95).
-- PLACEHOLDER: no.
NotificationConfig.SuccessCategory = 'Reward'

-- ---------------------------------------------------------------------------
-- Warning spam policy
-- ---------------------------------------------------------------------------

-- Same-id suppression window, in seconds.
--
-- DEFAULT: 2.0.
-- MEANING: a warning with the SAME catalog id, sent to the SAME
--   player, within this window is dropped (no toast, no sound, and
--   it does NOT consume burst budget). The key is
--   `"<userId>:<resolvedId>"` — note the RESOLVED id, so an unknown
--   id throttles against 'General_Generic'.
-- VALID RANGE: >= 0. 0 disables same-id suppression entirely.
-- SAFE TO CHANGE: yes. Raise it for a calmer UI, lower it for more
--   responsiveness.
-- READ BY: `NotificationService.NotifyWarning` (local
--   `REASON_WINDOW_S` literal at line 99).
-- PLACEHOLDER: no.
NotificationConfig.ReasonWindowSeconds = 2.0

-- Maximum warnings delivered to one player inside the burst window.
--
-- DEFAULT: 6.
-- MEANING: a rolling cap across ALL warning ids for a player. Once 6
--   warnings have been delivered within `BurstWindowSeconds`, further
--   warnings are dropped until the oldest falls out of the window.
-- VALID RANGE: >= 1. 1 would deliver only the first warning per
--   window.
-- SAFE TO CHANGE: yes.
-- READ BY: `NotificationService.NotifyWarning` (local `BURST_MAX`
--   literal at line 100).
-- PLACEHOLDER: no.
NotificationConfig.BurstMax = 6

-- The burst window, in seconds.
--
-- DEFAULT: 5.0.
-- MEANING: the rolling window over which delivered-warning stamps are
--   kept. Stamps older than this are discarded when the next warning
--   arrives.
-- VALID RANGE: >= 0.
-- SAFE TO CHANGE: yes.
-- READ BY: `NotificationService.NotifyWarning` (local
--   `BURST_WINDOW_S` literal at line 101).
-- PLACEHOLDER: no.
NotificationConfig.BurstWindowSeconds = 5.0

-- ---------------------------------------------------------------------------
-- Sound
-- ---------------------------------------------------------------------------

-- The SFX asset name played for every delivered warning.
--
-- DEFAULT: 'Error'.
-- MEANING: resolved as `ServerStorage.Assets.Sfx.<name>`. The child
--   may be a `Sound` directly or a folder containing one. A missing
--   asset logs ONE warning per name per server session and then the
--   notifications run silent.
-- VALID RANGE: the name of a child of `ServerStorage.Assets.Sfx`.
-- SAFE TO CHANGE: yes, if you author the asset with the new name.
-- READ BY: `NotificationService._playSfx` (hard-coded argument at
--   the end of `NotifyWarning`).
-- PLACEHOLDER: no — but the ASSET itself is a Studio asset that may
--   be absent in a fresh project.
NotificationConfig.WarningSound = 'Error'

-- Sound names a success entry may reference.
--
-- DEFAULT: { 'Approved', 'CashClaim', 'None' }.
-- MEANING: the catalog's `Sound` field for success entries. The
--   service plays the sound unless it is nil, '' or 'None' — 'None'
--   means "visual only". The shipped catalog uses 'Approved' for
--   most successes and 'CashClaim' for money.
-- VALID RANGE: any name present in `ServerStorage.Assets.Sfx`.
-- SAFE TO CHANGE: yes.
-- READ BY: `NotificationService.NotifySuccess` (the `entry.Sound`
--   check at lines 414-416); the list itself is not read by the code,
--   it is documentation of the catalog's vocabulary.
-- PLACEHOLDER: no.
NotificationConfig.SuccessSounds = { 'Approved', 'CashClaim', 'None' }

-- ---------------------------------------------------------------------------
-- Placeholder fallbacks
-- ---------------------------------------------------------------------------

-- Default text used when a well-known placeholder is missing.
--
-- DEFAULT: { EggName = 'Egg', AnimalName = 'Animal', Name = 'item',
--   Level = '?', Amount = '$0' }.
-- MEANING: the fallback passed to `RichTextFormatter.Entity` for the
--   three name placeholders, the value used when `Level` is not an
--   integer, and the value used when an `Amount` string fails
--   `BigNumber.sanitize`. Any placeholder NOT in this table (e.g.
--   `Duration`, `GearName`, `RewardText`) falls through to the generic
--   branch and renders as the literal '?'.
-- VALID RANGE: any string.
-- SAFE TO CHANGE: yes — but only the five shipped keys have an
--   effect; adding a key requires editing `_PLACEHOLDER_FALLBACK`
--   inside `NotificationService.lua`.
-- READ BY: `NotificationService._resolvePlaceholders` (local
--   `_PLACEHOLDER_FALLBACK` at line 237).
-- PLACEHOLDER: no.
NotificationConfig.PlaceholderFallbacks = {
	EggName = 'Egg',
	AnimalName = 'Animal',
	Name = 'item',
	Level = '?',
	Amount = '$0',
}

-- The generic text used for an unknown warning id.
--
-- DEFAULT: 'General_Generic'.
-- MEANING: the catalog id that `NotifyWarning` and `GetWarningText`
--   fall back to when the requested id is unknown or is not a
--   string. Its message is "You can't do that right now." — an
--   unknown warning is still delivered, never swallowed.
-- VALID RANGE: any id present in `Messages.Warning`.
-- SAFE TO CHANGE: yes, as long as the id exists.
-- READ BY: `NotificationService.GetWarningText` (line 305) and
--   `NotifyWarning` (the `resolvedId` fallback at line 343).
-- PLACEHOLDER: no.
NotificationConfig.UnknownWarningId = 'General_Generic'

-- ---------------------------------------------------------------------------
-- Message catalog reference
-- ---------------------------------------------------------------------------

-- The catalog module path and the two tables it must expose.
--
-- DEFAULT: 'ReplicatedStorage.Config.Presentation.Messages', with
--   `.Success` and `.Warning` arrays.
-- MEANING: the service requires this module and indexes
--   `Messages.Warning` and `Messages.Success` by `Id`. The shipped
--   catalog has 30 success entries and 105 warning entries
--   (81 'Warning', 20 'Silent', 4 'Internal').
-- VALID RANGE: n/a — this is a path reference, documentation only.
-- SAFE TO CHANGE: yes, but you must also edit the requires at
--   lines 68-69 of `NotificationService.lua`.
-- READ BY: not read directly — the requires are at
--   `NotificationService.lua:68` and `:69`.
-- PLACEHOLDER: no.
NotificationConfig.MessagesModule = 'ReplicatedStorage.Config.Presentation.Messages'

-- ---------------------------------------------------------------------------
-- External configuration the system reads
-- ---------------------------------------------------------------------------

-- The audio trace switch (read from
-- `ReplicatedStorage.Config.Systems.Debug`).
--
-- DEFAULT: false (as shipped in
--   `ReplicatedStorage/Config/Systems/Debug.lua`).
-- MEANING: when true, `_playSfx` logs the resolved sound id, volume
--   and parent to the debug console. It does NOT gate playback.
-- VALID RANGE: boolean.
-- SAFE TO CHANGE: yes.
-- READ BY: `NotificationService._playSfx` (line 169).
-- PLACEHOLDER: no.
NotificationConfig.AudioDebugEnabled = false

return table.freeze(NotificationConfig)
