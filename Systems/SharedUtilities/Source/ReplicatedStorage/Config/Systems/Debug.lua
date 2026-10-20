--!strict
--[[
	CANONICAL CONFIG (unified architecture).
	This module is the single source of truth for its domain; the legacy
	flat config under ReplicatedStorage.Config is a deprecated shim.
	New code must require this canonical path.
	Values below are preserved exactly from the pre-migration configs.
	Do NOT rebalance here without a gameplay review.
]]
--[[
	Debug
	===========
	Single source of truth for every DEBUG tunable: independent
	client/server master switches, per-tag whitelist, path
	visualization, persistence bypass, Studio test ids,
	per-subsystem verbose flags, and config validation.

	WHAT THIS CONTROLS
	------------------
	Which diagnostic streams print. Both switches default false:
	no debug console output on either side until a developer
	flips one on. The two switches are independent: flipping
	ServerDebug never enables client output and vice versa.

	Console workflow: set ServerDebug = true, run the server,
	read the server console. Set ClientDebug = true, run the
	client, read the client console. There is no in-game
	debug toggle (the debug HUD panel was removed).

	CANONICAL HOME
	-------------
	Debug is the single source of truth (the legacy GameConfig debug
	mirror was deleted in the unified-config migration). The server
	bootstrap and the client bootstrap each sync from Debug first.

	Do NOT create flags for systems that have no debug logging — every
	flag below maps to a real call site or an explicit near-term hook
	documented per-field.
]]

local Debug = {}

-- Independent master switches. Each side's Debug module checks
-- only its own flag: server output obeys ServerDebug, client
-- output obeys ClientDebug. CURRENT: both false (silent).
Debug.ServerDebug = false
Debug.ClientDebug = false

-- Optional per-tag whitelist. When non-empty, only tags in this set
-- print. Leave empty to print all enabled tags.
-- Tags used in the project: BS, LB, BR, PS, RM, CL, AO, CP.
-- CURRENT: {} (empty = all).
Debug.Tags = {}

-- When true, computed PathfindingService paths draw as neon-green
-- parts + lines in the world. Studio diagnosis only.
-- CURRENT: false.
Debug.DrawPaths = false

-- When true, PlayerService.LoadPlayerData bypasses ProfileService
-- and seeds a deterministic in-memory profile. Studio only.
-- CURRENT: false.
Debug.SkipPersistence = false

-- Studio multi-instance test UserIds (0, -1, -2, ...) accepted
-- alongside normal positive ids, Studio-only (IsStudio() gate).
-- CURRENT: true. Leaving on at publish time is harmless.
Debug.AllowStudioTestUserIds = true

-- --- Per-subsystem verbose flags -----------------------------------------
-- All default false. Each maps to an existing or explicitly planned
-- verbose site; do not add flags without a call site.

Debug.Subsystem = {
	Arena = false,
	Combat = false,
	Rewards = false,
	Overhead = false,
	Prompts = false,
	BaseLock = false,
	LevelUp = false,
	Performance = false,
	-- ArenaHitClient per-hit logs (ArenaHitPresentation VERBOSE).
	ArenaHitClient = false,
}

-- --- Config validation -----------------------------------------------------

-- When true, bootstrap runs ConfigValidator.ValidateAll() at boot
-- and fails LOUDLY in Studio on any issue (warn in live servers so
-- a bad tune never hard-crashes production).
-- CURRENT: true.
Debug.ConfigValidation = true

function Debug.Validate(): { string }
	local issues: { string } = {}
	if type(Debug.ServerDebug) ~= 'boolean' then
		issues[#issues + 1] = 'ServerDebug must be a boolean'
	end
	if type(Debug.ClientDebug) ~= 'boolean' then
		issues[#issues + 1] = 'ClientDebug must be a boolean'
	end
	if type(Debug.Tags) ~= 'table' then
		issues[#issues + 1] = 'Tags must be a table'
	end
	for name, v in pairs(Debug.Subsystem) do
		if type(v) ~= 'boolean' then
			issues[#issues + 1] = 'Subsystem.' .. tostring(name) .. ' must be a boolean'
		end
	end
	if type(Debug.ConfigValidation) ~= 'boolean' then
		issues[#issues + 1] = 'ConfigValidation must be a boolean'
	end
	return issues
end

-- --- Audio debug gate (new; readers previously hit undefined Debug.Audio) ---
-- When true, audio systems emit verbose debug logs. CURRENT: false.
-- (Readers compared `Debug.Audio == true`, so the missing field behaved
-- as false; this makes the intended default explicit and discoverable.)
Debug.Audio = {
	Enabled = false,
}
return table.freeze(Debug)
