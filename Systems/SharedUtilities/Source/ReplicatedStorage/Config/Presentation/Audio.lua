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
	Audio
	===========
	Single source of truth for AUDIO TUNABLES + policy: asset-key
	conventions, notification sound policy, and cleanup rules.

	WHAT THIS CONTROLS
	------------------
	Which sounds play where and how they clean up. Volumes/rolloff
	are AUTHORED on the Sound instances (Studio properties) — this
	module does not duplicate authored curves. Only INTENTIONAL
	code overrides (none today) would be tuned here.

	SOUND POLICY (existing, now documented)
	---------------------------------------
	* Success catalog entries carry Sound = 'Approved' (play the
	  shared approval cue) or 'None' (silent). See SuccessMessages.
	* Warnings play the shared Error cue via NotificationService.
	* Arena hit SFX: slots Attack1..Attack3 under
	  ReplicatedStorage.Assets.Arena.Sfx (mirrored at boot from
	  ServerStorage originals). Slot count + cleanup live in
	  ArenaPresentationConfig.Sfx (canonical there).
	* Steal victim alert: clones the authored 'Stealing' Sound into
	  the victim's PlayerGui (StealService). Source asset name below.
	* CashClaim: per-player SFX pool warmed at join (CollectFeedback).
	  Pool size + asset name below.
	* LevelUp: cached LevelUp SFX source (LevelUpPresentation).
	  Asset names below.

	ASSET REFERENCES
	----------------
	Names (not instances): presentation systems resolve these against
	the known replicated/server asset locations at runtime, so
	renaming an asset means updating ONE field here.
]]

local Audio = {}

-- Shared notification cues (resolved by NotificationService).
Audio.Notification = {
	-- Success entries with Sound='Approved' play this cue.
	SuccessCueName = 'Approved',
	-- Warnings play this cue.
	ErrorCueName = 'Error',
}

-- Steal victim alert source name (authored Sound cloned into
-- the victim's PlayerGui). CURRENT: 'Stealing'.
Audio.StealAlertSoundName = 'Stealing'

-- CashClaim collect feedback SFX pool (CollectFeedback).
-- Pool size per player, warmed at join. A short sting with
-- collections at most ~1/s apart (income tick) means 4
-- overlapping voices can never exhaust; rapid legitimate
-- claims overlap instead of truncating. Fixed bound: never
-- grows, never Debris-churned, replicates once.
-- CURRENT: 4.
-- NOTE: the button-press/VFX FEEL knobs that used to live here moved to
-- World.Bases (Bases.Collector.Feel) — this module keeps audio only.
Audio.Collect = {
	PoolSize = 4,
}

-- LevelUp celebration sources (LevelUpPresentation resolves these
-- under ServerStorage.Assets.Vfx / Sfx).
Audio.LevelUp = {
	VfxAssetName = 'Upgrade',
	SfxAssetName = 'LevelUp',
}

-- Arena asset roots (slots + cleanup canonical in
-- ArenaPresentationConfig.Sfx; roots documented here).
Audio.Arena = {
	VfxRoot = 'Vfx',
	SfxRoot = 'Sfx',
	VfxAssetName = 'Attack1',
	SfxSlotPrefix = 'Attack',
}

function Audio.Validate(): { string }
	local issues: { string } = {}
	if type(Audio.StealAlertSoundName) ~= 'string' or Audio.StealAlertSoundName == '' then
		issues[#issues + 1] = 'StealAlertSoundName must be a non-empty string'
	end
	if type(Audio.Collect.PoolSize) ~= 'number' or Audio.Collect.PoolSize < 1 then
		issues[#issues + 1] = 'Collect.PoolSize must be a number >= 1'
	end
	return issues
end

return table.freeze(Audio)
