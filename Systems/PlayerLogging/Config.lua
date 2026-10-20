--!strict
--[[
	PlayerLogging — consolidated tunables
	======================================
	A read-only, commented copy of every tunable the player-monitoring
	system exposes.

	This file does NOT change the behaviour of the running game:
	neither `PlayerLogger` nor `PlayerRegistry` requires it. The
	tunables live in
	`ServerScriptService/PlayerLogger/PlayerLoggerConfig.lua`.

	It exists so a new game can see every knob in one place and copy
	the values it wants to change into its own copy of the config.

	When you fork the system, edit
	`PlayerLoggerConfig.lua` directly (and mirror it here), or replace
	that module with this one and change the requires in
	`PlayerLogger.lua` / `PlayerRegistry.lua` to point at it.

	SECURITY: this file must never contain a webhook URL, an API key
	or any other credential. The URL is a secret and belongs in a
	Studio place file (or a runtime attribute), never in source
	control. Only the ATTRIBUTE NAME belongs here.
]]

local PlayerLoggingConfig = {}

-- ---------------------------------------------------------------------------
-- Secret location (NOT the secret itself)
-- ---------------------------------------------------------------------------

-- The NAME of the `ServerScriptService` string attribute that holds the
-- Discord webhook URL.
--
-- DEFAULT: 'PlayerLoggerWebhookUrl'.
-- MEANING: `PlayerLogger._readWebhookUrl()` does
--   `ServerScriptService:GetAttribute(Config.WebhookAttribute)` and
--   accepts the value only when it is a string matching
--   `^https://discord%.com/api/webhooks/`. The URL is read ONCE, at
--   `PlayerLogger.Init()`, and is never logged, never replicated and
--   never sent to a client.
--
--   Set it in Studio (place file):
--     ServerScriptService:SetAttribute('PlayerLoggerWebhookUrl', '<url>')
--   or at runtime before the first `Init()`.
--
-- VALID RANGE: any attribute name; the value must match the Discord
--   webhook URL pattern or delivery stays off.
-- SAFE TO CHANGE: yes.
-- READ BY: `PlayerLogger._readWebhookUrl` (via
--   `PlayerLoggerConfig.WebhookAttribute`).
-- PLACEHOLDER: no — but the ATTRIBUTE VALUE is a placeholder you must
--   supply yourself. Never commit the real URL.
PlayerLoggingConfig.WebhookAttribute = 'PlayerLoggerWebhookUrl'

-- The URL pattern the logger validates against. Listed here for
-- reference; the code inlines it.
--
-- DEFAULT: '^https://discord%.com/api/webhooks/'.
-- MEANING: a value that does not match is treated as absent and the
--   logger degrades to registry-only mode.
-- VALID RANGE: n/a.
-- SAFE TO CHANGE: only by editing `PlayerLogger._readWebhookUrl`.
-- READ BY: `PlayerLogger._readWebhookUrl` (line 268, inlined).
-- PLACEHOLDER: no.
PlayerLoggingConfig.WebhookUrlPattern = '^https://discord%.com/api/webhooks/'

-- The `username` field sent in the webhook body.
--
-- DEFAULT: 'Brainrot Arena'.
-- MEANING: the display name Discord shows for the bot that posts the
--   embed. Hard-coded in `PlayerLogger._postEmbed` (`username =
--   'Brainrot Arena'`).
-- VALID RANGE: any string.
-- SAFE TO CHANGE: yes, but you must edit `PlayerLogger._postEmbed`.
-- READ BY: `PlayerLogger._postEmbed` (line 292).
-- PLACEHOLDER: yes — this is Brainrot Arena's name. Replace it.
PlayerLoggingConfig.WebhookUsername = 'Brainrot Arena'

-- ---------------------------------------------------------------------------
-- Registry storage
-- ---------------------------------------------------------------------------

-- The DataStore name for the all-time player registry.
--
-- DEFAULT: 'p7_PlayerRegistry_v1'.
-- MEANING: a DEDICATED DataStore, separate from the gameplay
--   profile store. The logger's data never touches the player's
--   profile. One key per player (`<prefix><userId>`) so the registry
--   grows without one ever-growing blob.
-- VALID RANGE: any DataStore name. The 'p7_' prefix is a project
--   convention; a new game should use its own prefix.
-- SAFE TO CHANGE: yes — but changing it orphans every existing
--   registry entry (they live in the old store).
-- READ BY: `PlayerRegistry._getStore`.
-- PLACEHOLDER: yes — the 'p7_' prefix is Brainrot Arena's project id.
PlayerLoggingConfig.RegistryStoreName = 'p7_PlayerRegistry_v1'

-- The key prefix for registry entries.
--
-- DEFAULT: 'player_'.
-- MEANING: the full key is `'player_<userId>'`. Keying per player
--   (rather than one blob) lets the registry be paged through the
--   Roblox Open Cloud DataStore API.
-- VALID RANGE: any string.
-- SAFE TO CHANGE: yes — changing it orphans existing entries.
-- READ BY: `PlayerRegistry.KeyFor`.
-- PLACEHOLDER: no.
PlayerLoggingConfig.RegistryKeyPrefix = 'player_'

-- ---------------------------------------------------------------------------
-- Delivery bounds
-- ---------------------------------------------------------------------------

-- Maximum number of embeds held in the in-memory queue.
--
-- DEFAULT: 200.
-- MEANING: when the queue is at the cap, the OLDEST embed is dropped
--   to make room for the new one. A diagnostic is logged on the 1st
--   drop and every 50th thereafter.
-- VALID RANGE: >= 1.
-- SAFE TO CHANGE: yes. Lower it to reduce memory; raise it to ride
--   out a sink outage.
-- READ BY: `PlayerLogger._enqueue`.
-- PLACEHOLDER: no.
PlayerLoggingConfig.QueueCap = 200

-- Minimum seconds between two webhook POSTs.
--
-- DEFAULT: 1.2.
-- MEANING: the worker's send gap. 1.2 s is ~50 posts/minute, which
--   is slightly ABOVE Discord's ~30 posts/minute limit, so 429s are
--   expected and are handled by the `Retry-After` backoff. Set it to
--   2.0 to stay under the limit.
-- VALID RANGE: >= 0. 0 sends as fast as the HTTP round-trip allows.
-- SAFE TO CHANGE: yes.
-- READ BY: `PlayerLogger._worker`.
-- PLACEHOLDER: no.
PlayerLoggingConfig.SendIntervalSeconds = 1.2

-- Maximum attempts per embed before it is dropped.
--
-- DEFAULT: 3.
-- MEANING: total attempts (the first try plus retries). After the
--   third failure the embed is discarded with a
--   `Debug.Warn('PLOG', 'webhook delivery failed; event dropped', ...)`.
--   The attempt count is per item, not global.
-- VALID RANGE: >= 1.
-- SAFE TO CHANGE: yes.
-- READ BY: `PlayerLogger._worker`.
-- PLACEHOLDER: no.
PlayerLoggingConfig.MaxAttempts = 3

-- Backoff, in seconds, between attempts.
--
-- DEFAULT: `{ 2, 8 }`.
-- MEANING: attempt 1 waits 2 s, attempt 2 waits 8 s. Attempts beyond
--   the list reuse the LAST entry, so the wait never grows without
--   bound. A 429 `Retry-After` overrides this with
--   `max(backoff, retryAfter)`.
-- VALID RANGE: any array of positive numbers.
-- SAFE TO CHANGE: yes. Do not make it unbounded.
-- READ BY: `PlayerLogger._worker`.
-- PLACEHOLDER: no.
PlayerLoggingConfig.RetryBackoffSeconds = { 2, 8 }

-- Maximum embeds drained synchronously on server shutdown.
--
-- DEFAULT: 5.
-- MEANING: `BindToClose` sets the closing flag and then best-effort
--   POSTs up to this many queued embeds. It does NOT wait for
--   `ShutdownFlushMax` to succeed — it is a fire-and-forget drain.
--   Registry writes in flight are NOT drained.
-- VALID RANGE: >= 0.
-- SAFE TO CHANGE: yes.
-- READ BY: `PlayerLogger.Init` (the `BindToClose` handler).
-- PLACEHOLDER: no.
PlayerLoggingConfig.ShutdownFlushMax = 5

-- ---------------------------------------------------------------------------
-- Event toggles
-- ---------------------------------------------------------------------------

-- Which events are logged at all.
--
-- DEFAULT: all six true.
-- MEANING: `NotifyJoin` checks `Events.Join`; `NotifyLeave` checks
--   `Events.Leave`; `LogMilestone` checks `Events[kind]` and
--   **silently returns** for any kind that is not listed as `true`.
--   Disabling an event does not disable the registry write for
--   join/leave — the session is still recorded, but the embed is
--   dropped.
-- VALID RANGE: booleans.
-- SAFE TO CHANGE: yes.
-- READ BY: `PlayerLogger.NotifyJoin`, `.NotifyLeave`, `.LogMilestone`.
-- PLACEHOLDER: no.
PlayerLoggingConfig.Events = {
	Join = true,
	Leave = true,
	TutorialCompleted = true,
	ArenaCompleted = true,
	RebirthSucceeded = true,
	PurchaseGranted = true,
}

-- The milestone kinds the system knows about.
--
-- DEFAULT: the six keys of `Events` above.
-- MEANING: the set of `kind` strings that `LogMilestone` accepts.
--   `MILESTONE_COPY` in `PlayerLogger.lua` holds the title/description
--   for each; an unknown kind renders the generic `'📌 Event'` embed.
-- VALID RANGE: any set of strings, matched against `Events`.
-- SAFE TO CHANGE: yes — add a key to BOTH `Events` and `MILESTONE_COPY`.
-- READ BY: `PlayerLogger.LogMilestone` (via `Config.Events[kind]`).
-- PLACEHOLDER: yes — these are Brainrot Arena's milestones.
PlayerLoggingConfig.MilestoneKinds = {
	'TutorialCompleted',
	'ArenaCompleted',
	'RebirthSucceeded',
	'PurchaseGranted',
}

-- ---------------------------------------------------------------------------
-- Embed colours (decimal)
-- ---------------------------------------------------------------------------

-- The Discord accent colour per event kind.
--
-- DEFAULT: Join 3066993 (green), Leave 15158332 (red),
--   TutorialCompleted 3447003 (blue), ArenaCompleted 10181046
--   (purple), RebirthSucceeded 15844367 (gold), PurchaseGranted
--   5763719 (teal).
-- MEANING: the `color` field of each embed. Discord renders it as the
--   accent bar on the left of the embed.
-- VALID RANGE: 0 .. 16777215 (24-bit RGB).
-- SAFE TO CHANGE: yes.
-- READ BY: `PlayerLogger.BuildJoinEmbed`, `.BuildLeaveEmbed`,
--   `.BuildMilestoneEmbed` (the `MILESTONE_COPY` table).
-- PLACEHOLDER: no — these are ordinary palette choices.
PlayerLoggingConfig.Colors = {
	Join = 3066993,
	Leave = 15158332,
	TutorialCompleted = 3447003,
	ArenaCompleted = 10181046,
	RebirthSucceeded = 15844367,
	PurchaseGranted = 5763719,
}

-- ---------------------------------------------------------------------------
-- Discord limits (enforced by the builders)
-- ---------------------------------------------------------------------------

-- The Discord field limits the builders enforce.
--
-- DEFAULT: title 256, description 4096, fieldName 256, fieldValue
--   1024, footer 2048, maxFields 25.
-- MEANING: `_truncate` cuts over-long text and appends `'…'`; the
--   milestone builder trims the field array to 25 entries. Exceeding
--   any of these makes Discord reject the whole payload.
-- VALID RANGE: these are Discord's hard limits — do not raise them.
-- SAFE TO CHANGE: no.
-- READ BY: `PlayerLogger._truncate`, `._field`, `.BuildMilestoneEmbed`.
-- PLACEHOLDER: no.
PlayerLoggingConfig.DiscordLimits = {
	Title = 256,
	Description = 4096,
	FieldName = 256,
	FieldValue = 1024,
	Footer = 2048,
	MaxFields = 25,
}

return table.freeze(PlayerLoggingConfig)
