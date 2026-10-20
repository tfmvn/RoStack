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
	Stealing
	===========
	Single source of truth for steal-system TUNABLES: request
	cooldown and victim-alert cleanup.

	WHAT THIS CONTROLS
	------------------
	Steal request pacing + robbery-alert lifetime. The steal RULES
	(ownership, lock, distance, atomic take-carry-deliver-transfer)
	stay code-owned in StealService — they are security logic, not
	tuning. Prompt LABELS live in PromptConfig.Steal; the alert
	SOUND NAME lives in AudioConfig.StealAlertSoundName.

	All values copied exactly from StealService's locals.
	Server authoritative: YES.
]]

local Stealing = {}

-- Anti-spam: at most one steal request per player per window.
-- Rejections are cheap (no mutation), so this only blunts
-- RemoteEvent/prompt spam, never legitimate play.
-- Type: number. Unit: seconds. Valid: >= 0. CURRENT: 0.5.
Stealing.Cooldown = 0.5

-- Victim alert cleanup: sound length + Pad, or Fallback when the
-- length is unreadable. CURRENT: +0.5s, fallback 3s.
Stealing.AlertCleanupPad = 0.5
Stealing.AlertFallbackCleanup = 3

-- Thief slow while steal-carrying: WalkSpeed multiplier applied at
-- steal start and restored (to the captured pre-steal value) on
-- every steal exit (complete / rollback tiers / leave cleanup).
-- Relative (not absolute) so admin-set speeds survive the round
-- trip. CURRENT: 0.6.
Stealing.StealSpeedMultiplier = 0.6

-- Thief-only camera presentation while steal-carrying an
-- animal (read by the client StealPresentationController;
-- the server never touches FieldOfView). FOVMultiplier
-- narrows from the player's CURRENT FOV (relative, so
-- custom zooms survive the round trip); FOVTweenTime is the
-- smooth transition each way. CURRENT: 0.9 / 0.3s.
Stealing.StealPresentation = {
	FOVMultiplier = 0.9,
	FOVTweenTime = 0.3,
}

function Stealing.Validate(): { string }
	local issues: { string } = {}
	if type(Stealing.Cooldown) ~= 'number' or Stealing.Cooldown ~= Stealing.Cooldown or Stealing.Cooldown < 0 then
		issues[#issues + 1] = 'Cooldown must be a number >= 0'
	end
	if type(Stealing.AlertFallbackCleanup) ~= 'number' or Stealing.AlertFallbackCleanup <= 0 then
		issues[#issues + 1] = 'AlertFallbackCleanup must be a number > 0'
	end
	if
		type(Stealing.StealSpeedMultiplier) ~= 'number'
		or Stealing.StealSpeedMultiplier ~= Stealing.StealSpeedMultiplier
		or Stealing.StealSpeedMultiplier <= 0
	then
		issues[#issues + 1] = 'StealSpeedMultiplier must be a number > 0'
	end
	local pres = Stealing.StealPresentation
	if type(pres) ~= 'table' then
		issues[#issues + 1] = 'StealPresentation must be a table'
	else
		if
			type(pres.FOVMultiplier) ~= 'number'
			or pres.FOVMultiplier ~= pres.FOVMultiplier
			or pres.FOVMultiplier <= 0
			or pres.FOVMultiplier >= 1
		then
			issues[#issues + 1] = 'StealPresentation.FOVMultiplier must narrow (0 < x < 1)'
		end
		if type(pres.FOVTweenTime) ~= 'number' or pres.FOVTweenTime ~= pres.FOVTweenTime or pres.FOVTweenTime < 0 then
			issues[#issues + 1] = 'StealPresentation.FOVTweenTime must be a number >= 0'
		end
	end
	return issues
end

return table.freeze(Stealing)
