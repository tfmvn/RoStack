--!strict
--!native
--[[
	PlayerLogger.PlayerLoggerConfig
	================================
	Static tuning for the player-monitoring subsystem (logger +
	registry). DATA ONLY — no services, no secrets, no HTTP.

	Where the Discord webhook URL lives (NOT here, NOT in git):
	  * Set a STRING ATTRIBUTE named `PlayerLoggerWebhookUrl`
	    on ServerScriptService in Studio (place file only —
	    the place is not committed to this repository).
	  * The value is read server-side at PlayerLogger.Init and
	    never replicated, never logged, never sent to clients.
	  * Missing/invalid → Discord delivery stays disabled and
	    the game runs normally (registry still updates,
	    diagnostics note the gap once).

	Roblox game settings: `HttpService.HttpEnabled` must be ON
	for webhook delivery (Studio: Game Settings → Security →
	Enable Studio Access to APIs is NOT enough — the live game
	needs HTTP Requests enabled). The logger probes the flag
	and degrades to registry-only when HTTP is off.
]]

local PlayerLoggerConfig = {}

-- NAME of the ServerScriptService string attribute that holds the
-- Discord webhook URL. The URL itself is a SECRET and must never
-- live in source, in a config file, or in version control.
--
-- Set the attribute in the Studio place:
--   ServerScriptService:SetAttribute('PlayerLoggerWebhookUrl', '<url>')
-- or at runtime before the first log call.
--
-- If the attribute is absent, the logger degrades to registry-only
-- delivery (see PlayerLogger.lua:267) and never errors.
--
-- SECURITY NOTE (library extraction): the source game shipped a live
-- webhook URL as a literal in this field, immediately under a comment
-- saying it belonged in Studio. That literal is removed here and the
-- field now holds the attribute NAME, which is what the consuming
-- code actually expects. See ../../../SECURITY_NOTES.md.
PlayerLoggerConfig.WebhookAttribute = 'PlayerLoggerWebhookUrl'

-- Persistent all-time registry (separate DataStore from the
-- gameplay profile — logger data never touches it).
PlayerLoggerConfig.RegistryStoreName = 'p7_PlayerRegistry_v1'
PlayerLoggerConfig.RegistryKeyPrefix = 'player_'

-- Delivery bounds: Discord allows ~30 webhook posts/minute.
PlayerLoggerConfig.QueueCap = 200
PlayerLoggerConfig.SendIntervalSeconds = 1.2
PlayerLoggerConfig.MaxAttempts = 3
-- Backoff between attempts (attempts beyond this list reuse
-- the last entry). No unbounded loops, ever.
PlayerLoggerConfig.RetryBackoffSeconds = { 2, 8 }
-- Best-effort synchronous drain on server shutdown.
PlayerLoggerConfig.ShutdownFlushMax = 5

-- Per-kind toggles. Join/Leave are the operational core;
-- milestones ride the same queue. High-frequency gameplay
-- (attacks, movement, income ticks) is NEVER logged.
PlayerLoggerConfig.Events = {
	Join = true,
	Leave = true,
	TutorialCompleted = true,
	ArenaCompleted = true,
	RebirthSucceeded = true,
	PurchaseGranted = true,
}

-- Embed colors (decimal).
PlayerLoggerConfig.Colors = {
	Join = 3066993, -- green
	Leave = 15158332, -- red
	TutorialCompleted = 3447003, -- blue
	ArenaCompleted = 10181046, -- purple
	RebirthSucceeded = 15844367, -- gold
	PurchaseGranted = 5763719, -- teal
}

return table.freeze(PlayerLoggerConfig)
