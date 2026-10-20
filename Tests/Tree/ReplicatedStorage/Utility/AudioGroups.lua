--!strict
--[[
	AudioGroups
	===========
	Single source of truth for the global SoundGroup architecture.

	Runtime hierarchy (ONE authoritative tree):

	  SoundService
	  └── GameSound <SoundGroup>   — MASTER game volume (EVERYTHING)
	      ├── BgmSound <SoundGroup> — music-only volume (nested group;
	      │   effective music level = GameSound × BgmSound × Sound)
	      │   ├── Bgm <Sound>
	      │   └── ArenaBgm <Sound>
	      ├── CashClaim / LevelUp / Pop / Reward / Stealing /
	      │   HitSfx / Approved / Error / Attack1..3 (server clones
	      │   + pools, each stamped GameSound at creation)
	      └── Attack1..3 (client arena-hit clones, stamped GameSound)

	Classification rule: Bgm + ArenaBgm are MUSIC (→ BgmSound);
	EVERYTHING else the game plays is SFX (→ GameSound). Every
	runtime Sound creation site (Instance.new, :Clone, prop-copy
	refresh, VFX-embedded sounds) assigns its group at creation
	time through AssignMusic/AssignSfx, so no sound can slip
	through ungrouped.

	Volume model: individual Sound.Volume stays authored per
	sound (per-sound balancing is untouched); the Settings
	sliders drive the group masters (GameSound.Volume for the
	GameSound slider, BgmSound.Volume for BackgroundMusic),
	which multiply with the per-sound volume at mix time. No
	per-sound loops. The BGM join fade tweens BgmSound.Volume
	from 0 to the saved music target (never the Sound volumes).

	Creation: the server creates both groups at bootstrap (they
	replicate to clients). Clients wait briefly for the
	replicated groups before creating local fallbacks, so the
	common case has exactly one shared hierarchy.
]]

local SoundService = game:GetService('SoundService')

local AudioGroups = {}

AudioGroups.GameSoundGroupName = 'GameSound'
AudioGroups.BgmSoundGroupName = 'BgmSound'

-- Legacy names from the previous flat architecture
-- (SoundService.Music + SoundService.SFX). No longer created;
-- listed so future readers know they are retired on purpose.
AudioGroups.RetiredGroupNames = { 'Music', 'SFX' }

local function clamp01(value: number): number
	if type(value) ~= 'number' or value ~= value then
		return 1
	end
	return math.clamp(value, 0, 1)
end

-- Find-or-create a SoundGroup. `parent` is SoundService for
-- GameSound, the GameSound group for BgmSound (nested groups
-- multiply down the chain). `waitSeconds` lets clients wait
-- for the server-replicated groups before creating a local
-- fallback (server passes 0 and creates immediately).
local function getOrCreateGroup(name: string, parent: Instance, waitSeconds: number): SoundGroup?
	local found: SoundGroup? = nil
	pcall(function()
		local direct = parent:FindFirstChild(name)
		if direct ~= nil and direct:IsA('SoundGroup') then
			found = direct
			return
		end
		if waitSeconds > 0 then
			local waited = parent:WaitForChild(name, waitSeconds)
			if waited ~= nil and waited:IsA('SoundGroup') then
				found = waited :: SoundGroup
				return
			end
		end
		local made = Instance.new('SoundGroup')
		made.Name = name
		made.Parent = parent
		found = made
	end)
	return found
end

-- Idempotent: safe to call from server bootstrap, every client
-- controller, and every play site. Returns the live groups.
-- `replicatedWait` is the client grace period for the
-- server-owned hierarchy (server passes 0).
function AudioGroups.EnsureGroups(replicatedWait: number?): { GameSound: SoundGroup?, BgmSound: SoundGroup? }
	local waitSeconds = if type(replicatedWait) == 'number' then replicatedWait :: number else 0
	local gameSound = getOrCreateGroup(AudioGroups.GameSoundGroupName, SoundService, waitSeconds)
	local bgmSound: SoundGroup? = nil
	if gameSound ~= nil then
		bgmSound = getOrCreateGroup(AudioGroups.BgmSoundGroupName, gameSound, 0)
	end
	return {
		GameSound = gameSound,
		BgmSound = bgmSound,
	}
end

function AudioGroups.GameSoundGroup(): SoundGroup?
	local groups = AudioGroups.EnsureGroups(0)
	return groups.GameSound
end

function AudioGroups.BgmSoundGroup(): SoundGroup?
	local groups = AudioGroups.EnsureGroups(0)
	return groups.BgmSound
end

-- Stamp a sound as MUSIC (Bgm / ArenaBgm → nested BgmSound).
-- Never throws.
function AudioGroups.AssignMusic(sound: Sound)
	pcall(function()
		local groups = AudioGroups.EnsureGroups(0)
		if groups.BgmSound ~= nil then
			(sound :: Sound).SoundGroup = groups.BgmSound
		end
	end)
end

-- Stamp a sound as SFX (every other game sound → GameSound).
-- Never throws.
function AudioGroups.AssignSfx(sound: Sound)
	pcall(function()
		local groups = AudioGroups.EnsureGroups(0)
		if groups.GameSound ~= nil then
			(sound :: Sound).SoundGroup = groups.GameSound
		end
	end)
end

-- Master controls (Settings sliders). Per-sound Volume is
-- untouched; the groups multiply at mix time.
-- SetMusicVolume → BgmSound (BackgroundMusic slider).
function AudioGroups.SetMusicVolume(value: number)
	pcall(function()
		local groups = AudioGroups.EnsureGroups(0)
		if groups.BgmSound ~= nil then
			(groups.BgmSound :: SoundGroup).Volume = clamp01(value)
		end
	end)
end

-- SetSfxVolume → GameSound (GameSound slider, master of ALL
-- game audio including the nested BgmSound).
function AudioGroups.SetSfxVolume(value: number)
	pcall(function()
		local groups = AudioGroups.EnsureGroups(0)
		if groups.GameSound ~= nil then
			(groups.GameSound :: SoundGroup).Volume = clamp01(value)
		end
	end)
end

return table.freeze(AudioGroups)
