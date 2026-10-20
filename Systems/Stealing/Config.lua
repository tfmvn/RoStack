--!strict
--[[
	Stealing — consolidated tunables for the Steal system
	=======================================================

	DERIVED FROM (values copied EXACTLY, not re-tuned):
	  * Source/ReplicatedStorage/Config/World/Stealing.lua  (the canonical
	    config module in the source game; roblox destination
	    `ReplicatedStorage.Config.World.Stealing`)
	  * The constants `StealService.lua` actually READS from that module.

	Everything below is a REAL value from the real source. Nothing is
	invented, and nothing is a placeholder.

	THE VALUES IN OTHER SYSTEMS' CONFIGS (read by StealService but owned
	elsewhere) are NOT duplicated here — they stay in their owners' modules:
	  * PromptConfig.CarryMaxDistance            (Carry, 8)
	  * PromptConfig.AnimalPickup.MaxActivationDistance (Carry, 8)
	  * PromptConfig.Steal.*                      (Carry — the prompt def)
	  * AudioConfig.StealAlertSoundName          (SharedUtilities, 'Stealing')
	  * DebugConfig.Audio.Enabled                 (SharedUtilities, false)

	Install destination: `ReplicatedStorage.Config.World.Stealing` — the
	require path in StealService is
	`require(ReplicatedStorage.Config.World.Stealing)`, so the file must
	live at that exact path for the require to resolve unchanged.
]]

local Stealing = {}

-- Anti-spam: at most one steal request per player per window.
-- Rejections are cheap (no mutation), so this only blunts
-- RemoteEvent/prompt spam, never legitimate play.
-- Type: number. Unit: seconds. Valid: >= 0. CURRENT: 0.5.
--
-- DEFAULT: 0.5
-- MEANING: the minimum interval between two steal REQUESTS from the same
--   player. The window is consumed by the first attempt, whether it
--   succeeded or failed.
-- VALID RANGE: >= 0 (0 disables the rate limit entirely).
-- SAFE TO CHANGE: yes, freely. It is a pure pacing knob — no other
--   system reads it and no state depends on it.
-- READ BY: ServerScriptService.Steal.StealService — line 110
--   (`local STEAL_COOLDOWN_S = StealConfig.Cooldown`), used at line 673
--   in `TrySteal`.
-- PLACEHOLDER: no.
Stealing.Cooldown = 0.5

-- Victim alert cleanup: sound length + Pad, or Fallback when the
-- length is unreadable. CURRENT: +0.5s, fallback 3s.
--
-- DEFAULT: 0.5
-- MEANING: extra seconds added to the measured `Sound.TimeLength` before
--   the cloned robbery-alert SFX is handed to `Debris:AddItem`. Gives the
--   sound a little tail so it is not cut mid-playback.
-- VALID RANGE: >= 0. There is no upper bound enforced anywhere — a very
--   large value keeps the clone alive in the victim's PlayerGui for a
--   long time.
-- SAFE TO CHANGE: yes. Presentation only; it never affects ownership,
--   transfer, or rollback. NOTE: this value is NOT covered by
--   `Stealing.Validate()` — a negative value makes the clone get
--   destroyed before it can play.
-- READ BY: ServerScriptService.Steal.StealService — line 359
--   (`length = timeLength + StealConfig.AlertCleanupPad`).
-- PLACEHOLDER: no.
Stealing.AlertCleanupPad = 0.5

-- Fallback SFX lifetime used when `Sound.TimeLength` cannot be read
-- (not loaded yet, malformed asset, `pcall` failure).
--
-- DEFAULT: 3
-- MEANING: seconds the cloned robbery-alert SFX survives in the victim's
--   `PlayerGui` when its real length is unknown.
-- VALID RANGE: > 0 (enforced by `Stealing.Validate()`).
-- SAFE TO CHANGE: yes, but only upward is sensible — 3 seconds is a
--   plausible length for a short "you were robbed" sting. A much smaller
--   value truncates the sound.
-- READ BY: ServerScriptService.Steal.StealService — line 354
--   (`local length = StealConfig.AlertFallbackCleanup`).
-- PLACEHOLDER: no.
Stealing.AlertFallbackCleanup = 3

-- Thief slow while steal-carrying: WalkSpeed multiplier applied at
-- steal start and restored (to the captured pre-steal value) on
-- every steal exit (complete / rollback tiers / leave cleanup).
-- Relative (not absolute) so admin-set speeds survive the round
-- trip. CURRENT: 0.6.
--
-- DEFAULT: 0.6
-- MEANING: the multiplier applied to the thief's `Humanoid.WalkSpeed`
--   while they carry a stolen object. The value is RELATIVE: the applied
--   speed is `currentSpeed * 0.6`, and the restore writes back the
--   captured pre-steal speed exactly, so an admin-set speed survives the
--   round trip. If there was no valid snapshot, the thief is never
--   slowed and the restore is a no-op.
-- VALID RANGE: > 0 (enforced by `Stealing.Validate()`). 1.0 means "no
--   slow"; 0.5 is half speed.
-- SAFE TO CHANGE: yes, but it is a gameplay-balance knob — review it with
--   the same care as any movement value. It only affects the THIEF, and
--   only while the steal carry is live.
-- READ BY: ServerScriptService.Steal.StealService — line 609
--   (`hum.WalkSpeed = current * StealConfig.StealSpeedMultiplier`).
-- PLACEHOLDER: no.
Stealing.StealSpeedMultiplier = 0.6

-- Thief-only camera presentation while steal-carrying an
-- animal (read by the client StealPresentationController;
-- the server never touches FieldOfView). FOVMultiplier
-- narrows from the player's CURRENT FOV (relative, so
-- custom zooms survive the round trip); FOVTweenTime is the
-- smooth transition each way. CURRENT: 0.9 / 0.3s.
--
-- DEFAULT: { FOVMultiplier = 0.9, FOVTweenTime = 0.3 }
-- MEANING: camera presentation for the thief while they steal-carry an
--   ANIMAL. `FOVMultiplier` narrows the camera from the player's CURRENT
--   field of view (relative, so a custom zoom survives the round trip) —
--   a subtle "heft", never a minigame. `FOVTweenTime` is the duration in
--   seconds of the tween each way (in and out).
--   The SERVER never reads the field of view; these values are read by
--   the CLIENT `StealPresentationController`
--   (StarterPlayer.StarterPlayerScripts.StealPresentationController, in
--   the ClientPresentation system) via the `PlayerState` remote.
--   The client applies the zoom ONLY when `CarriedSteal == true` AND
--   `CarriedKind == 'animal'` — egg steals keep the default camera, and
--   only the thief's own camera moves.
-- VALID RANGE: FOVMultiplier must narrow, i.e. 0 < x < 1 (enforced by
--   `Stealing.Validate()`). FOVTweenTime >= 0 (also enforced). The client
--   has its own fallbacks (0.9 / 0.3) if the values are unreadable.
-- SAFE TO CHANGE: yes — pure presentation, zero gameplay effect. Both
--   values are read live, so a Studio tweak applies without a restart.
-- READ BY: StarterPlayer.StarterPlayerScripts.StealPresentationController
--   — `_targetFov` (line 70) and `_tweenSeconds` (line 58).
-- PLACEHOLDER: no.
Stealing.StealPresentation = {
	FOVMultiplier = 0.9,
	FOVTweenTime = 0.3,
}

-- Validate the tunables above. Returns an array of human-readable issue
-- strings; an EMPTY array means the config is valid.
--
-- DEFAULT: n/a (a function, not a value)
-- MEANING: the single self-check for this config module. It is called
--   by the game's config validation pass at boot; it never throws and
--   never mutates.
-- VALID RANGE: n/a.
-- SAFE TO CHANGE: no — it is the validator. If you add a tunable, add a
--   check for it here.
-- READ BY: the source game's config validation pass. NOTE: it does NOT
--   validate `AlertCleanupPad` — that value is unchecked everywhere.
-- PLACEHOLDER: no.
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
