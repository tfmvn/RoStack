--!strict
--!native
--[[
	SettingsController
	==================
	Client owner of the authored `PlayerGui.Main.Settings` panel
	(BackgroundMusic / GameSound sliders, FastMode toggle). Never
	redesigns the GUI — only wires it.

	Audio model (global SoundGroup masters — see
	ReplicatedStorage.Utility.AudioGroups). ONE hierarchy:

	  SoundService
	  └── GameSound <SoundGroup>   (GameSound slider = master)
	      └── BgmSound <SoundGroup> (BackgroundMusic slider)
	          ├── Bgm <Sound>
	          └── ArenaBgm <Sound>

	Individual Sound.Volume stays authored per sound; the
	sliders drive the group masters (effective music =
	GameSound × BgmSound × Sound). Every runtime play site
	stamps its own group at creation; the two Studio-authored
	music tracks are stamped BgmSound when adopted here, and
	the adopted track plays immediately at join. Arena mode
	(ArenaState.Session / RaidEnd) crossfades Bgm ↔ ArenaBgm
	(out → 0, swap, in → authored base, ~1s each leg); both
	ride the same BgmSound master, so no separate arena volume
	exists. Authored per-track volumes are captured once and
	never destroyed by transitions.
	Open/close ownership lives in SettingsTopbar.client.lua
	(the fast-boot TopbarPlus icon); this controller only
	wires sliders/toggles/persistence/music and hides the
	panel on CloseButton as a fallback.
	FastMode has no gameplay/backend implementation anywhere in
	the project — the toggle persists and paints, and is
	reported as UI-only.

	Persistence: profile-backed via SaveSettings (debounced —
	sent on slider release and on toggle, never per pixel) and
	SettingsState push on load. Server sanitizes everything.
]]

local Players = game:GetService('Players')
local SoundService = game:GetService('SoundService')
local TweenService = game:GetService('TweenService')
local UserInputService = game:GetService('UserInputService')
local Workspace = game:GetService('Workspace')
local ReplicatedStorage = game:GetService('ReplicatedStorage')

local Debug = require(ReplicatedStorage.Utility.Debug)
local Remotes = require(ReplicatedStorage.Utility.Remotes)
local MenuPresentation = require(script.Parent.MenuPresentation)
local AudioGroups = require(ReplicatedStorage.Utility.AudioGroups)

local SettingsController = {}

local localPlayer = Players.LocalPlayer

local function warnUi(message: string)
	Debug.Warn('Settings', message)
end

local function logUi(message: string)
	Debug.Log('Settings', message)
end

local function logMusic(message: string)
	Debug.Log('ArenaMusic', message)
end

local wired = false
local saveRemote: RemoteEvent? = nil

-- --- Live settings (mirrors the last applied values) ----------------

local bgmValue = 1
local sfxValue = 1
local fastMode = false

-- --- Group masters ------------------------------------------------------
-- Slider changes drive the SoundGroup volumes directly (no
-- per-sound iteration). Groups are ensured here so masters work
-- even before the server bootstrap replicates its own copies.
-- BackgroundMusic → BgmSound.Volume; GameSound → GameSound.Volume
-- (master of everything, including the nested BgmSound).

-- Live music routing state. arenaMode selects the track; both
-- ride the same BgmSound master, so no separate arena volume.
local bgmTrack: Sound? = nil
local arenaTrack: Sound? = nil
local arenaMode = false

-- Arena crossfade tuning (single knob; transitions only — the
-- join itself stays instant, no join fade by design).
local ARENA_FADE_SECONDS = 1.0

-- Authored per-track Volume captured at first sight. Transitions
-- tween track volumes as base × level, so authored balancing is
-- never destroyed; the BgmSound group (user setting) stays the
-- single master on top.
local trackBase: { [Sound]: number } = {}

-- Transition generation + live tweens. A new authoritative state
-- (or slider input) cancels everything stale — transitions can
-- never stack, even across rapid arena re-entries.
local musicGen = 0
local musicTweens: { Tween } = {}

local function cancelMusicTweens()
	musicGen += 1
	pcall(function()
		for _, tw in ipairs(musicTweens) do
			pcall(function()
				(tw :: Tween):Cancel()
			end)
		end
	end)
	musicTweens = {}
end

-- Capture the authored per-track Volume BEFORE any transition
-- zeroes it. baseVolume() pins the fade target on its first
-- read, so a first read after `track.Volume = 0` would lock
-- the base (and every fade target) at 0 forever: the track
-- would Play() successfully yet stay completely silent. Adopt
-- runs before any transition, so capturing here is the primary
-- guarantee; startIncoming re-captures defensively for
-- late-replicating tracks. Never overwrites: a mid-transition
-- re-adopt must not mistake a faded volume for the authored one.
local function captureBaseVolume(track: Sound)
	if trackBase[track] ~= nil then
		return
	end
	pcall(function()
		trackBase[track] = track.Volume
	end)
end

local function baseVolume(track: Sound): number
	captureBaseVolume(track)
	local base = trackBase[track]
	if type(base) ~= 'number' then
		return 0
	end
	return base
end

-- Snap both masters immediately to the live slider values.
local function applyVolumes()
	AudioGroups.SetMusicVolume(bgmValue)
	AudioGroups.SetSfxVolume(sfxValue)
end

-- Tween one track toward base × level (event-driven completion;
-- stale generations are ignored). Nil-safe.
local function tweenTrackTo(track: Sound, level: number, gen: number, onDone: (() -> ())?)
	local target = baseVolume(track) * math.clamp(level, 0, 1)
	pcall(function()
		if math.abs(track.Volume - target) < 0.001 then
			track.Volume = target
			if onDone ~= nil then
				(onDone :: () -> ())()
			end
			return
		end
		local tw = TweenService:Create(
			track,
			TweenInfo.new(ARENA_FADE_SECONDS, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ Volume = target }
		)
		musicTweens[#musicTweens + 1] = tw
		tw.Completed:Connect(function(state: Enum.PlaybackState)
			if state ~= Enum.PlaybackState.Completed or gen ~= musicGen then
				return
			end
			if onDone ~= nil then
				(onDone :: () -> ())()
			end
		end)
		tw:Play()
	end)
end

-- Steady-state snap (boot, slider input, server push): cancel any
-- transition and put the mode-correct track at its authored base
-- (group masters carry the user level). Exactly one track plays.
local function ensureTrackPlayback()
	cancelMusicTweens()
	pcall(function()
		local wantArena = arenaMode and arenaTrack ~= nil
		local active = if wantArena then arenaTrack else bgmTrack
		local idle = if wantArena then bgmTrack else arenaTrack
		if idle ~= nil then
			if (idle :: Sound).IsPlaying then
				(idle :: Sound):Pause()
			end
			(idle :: Sound).Volume = 0
		end
		if active ~= nil then
			(active :: Sound).Looped = true
			(active :: Sound).Volume = baseVolume(active :: Sound)
			if bgmValue > 0 and not (active :: Sound).IsPlaying then
				(active :: Sound):Play()
				logUi(('track started name=%s'):format((active :: Sound).Name))
			elseif bgmValue <= 0 and (active :: Sound).IsPlaying then
				(active :: Sound):Pause()
			end
		else
			logUi(('no track for mode=%s (missing Sound?)'):format(if arenaMode then 'arena' else 'lobby'))
		end
	end)
end

-- Crossfade current → mode track: fade the outgoing track to 0,
-- swap (pause old, start new from 0), fade the incoming track to
-- its base. Mute-aware (target 0 → pause both, no Play). Missing
-- incoming track → stay on the current one, never silence music
-- by accident.
local function transitionTracks(toArena: boolean)
	cancelMusicTweens()
	local gen = musicGen
	pcall(function()
		local outgoing = if toArena then bgmTrack else arenaTrack
		local incoming = if toArena then arenaTrack else bgmTrack
		if incoming == nil then
			logUi(('no track for mode=%s — staying put'):format(if toArena then 'arena' else 'lobby'))
			logMusic(('no track for mode=%s — staying put'):format(if toArena then 'arena' else 'lobby'))
			ensureTrackPlayback()
			return
		end
		local function startIncoming()
			if gen ~= musicGen then
				return
			end
			local inc = incoming :: Sound
			-- Capture the authored base BEFORE zeroing (see
			-- captureBaseVolume): the first baseVolume() read
			-- pins the fade target forever, so it must see the
			-- authored volume, never the transition scratch 0.
			local base = baseVolume(inc)
			pcall(function()
				local groupName = if inc.SoundGroup ~= nil then inc.SoundGroup.Name else '<none>'
				logMusic(
					('incoming name=%s path=%s soundId=%s pre-play Volume=%.3f base=%.3f group=%s IsPlaying=%s'):format(
						inc.Name,
						inc:GetFullName(),
						if inc.SoundId == '' then '<EMPTY>' else inc.SoundId,
						inc.Volume,
						base,
						groupName,
						tostring(inc.IsPlaying)
					)
				)
			end)
			inc.Looped = true
			inc.Volume = 0
			if bgmValue > 0 then
				if not inc.IsPlaying then
					inc:Play()
				end
				logMusic(('%s Play() issued IsPlaying=%s'):format(inc.Name, tostring(inc.IsPlaying)))
				logMusic(('%s fading in target=%.3f'):format(inc.Name, base * 1))
				tweenTrackTo(inc, 1, gen, nil)
			else
				if inc.IsPlaying then
					inc:Pause()
				end
				logMusic(('%s muted (BackgroundMusic=0) — paused, no Play'):format(inc.Name))
			end
		end
		if outgoing ~= nil and (outgoing :: Sound).IsPlaying then
			logMusic(('%s fading out'):format((outgoing :: Sound).Name))
			tweenTrackTo(outgoing :: Sound, 0, gen, function()
				if gen ~= musicGen then
					return
				end
				logMusic(('%s fade complete'):format((outgoing :: Sound).Name))
				pcall(function()
					(outgoing :: Sound):Pause()
				end)
				logMusic(('%s paused'):format((outgoing :: Sound).Name))
				startIncoming()
			end)
		else
			if outgoing ~= nil then
				pcall(function()
					(outgoing :: Sound):Pause()
				end)
			end
			startIncoming()
		end
	end)
end

-- Flip between lobby Bgm and ArenaBgm via crossfade (never an
-- instant swap, never duplicated playback at steady state).
-- sessionId is log-only (generation fencing in musicGen keeps
-- stale cleanups from stopping a newer raid's track).
local function setArenaMode(active: boolean, sessionId: any)
	if active == arenaMode then
		return
	end
	arenaMode = active
	if active then
		logMusic(('entering Arena session=%s'):format(tostring(sessionId)))
	else
		logMusic(('Arena ended session=%s'):format(tostring(sessionId)))
	end
	transitionTracks(active)
	logUi(if active then 'arena mode: ArenaBgm' else 'arena mode off: Bgm')
end

-- --- Music track resolution --------------------------------------------

-- Find the Studio-authored track `name` (Bgm / ArenaBgm):
-- SoundService, then Workspace, then the server-mirrored
-- ReplicatedStorage template (mirrored at boot from
-- ServerStorage, which clients can never see). Tolerates a
-- Folder-wrapped track (uses its first descendant Sound).
local function findTrack(name: string): Sound?
	local found: Sound? = nil
	pcall(function()
		local function asSound(node: Instance?): Sound?
			if node == nil then
				return nil
			end
			if node:IsA('Sound') then
				return node
			end
			local inner = node:FindFirstChildWhichIsA('Sound', true)
			if inner ~= nil and inner:IsA('Sound') then
				return inner
			end
			return nil
		end
		found = asSound(SoundService:FindFirstChild(name, true))
		if found ~= nil then
			return
		end
		found = asSound(Workspace:FindFirstChild(name, true))
		if found ~= nil then
			return
		end
		local assets = ReplicatedStorage:FindFirstChild('Assets')
		local sfx = assets and assets:FindFirstChild('Sfx') or nil
		local node = sfx and sfx:FindFirstChild(name) or nil
		found = asSound(node)
	end)
	return found
end

-- Adopt BOTH music tracks (Bgm + ArenaBgm): stamp BgmSound
-- (authored Sound.Volume untouched). Playback is owned by
-- ensureTrackPlayback (mode-correct track, playing at join). ReplicatedStorage templates are
-- cloned into SoundService (templates cannot play); Workspace
-- tracks play positionally as authored.

-- Promote a found track to something audible. SoundService /
-- Workspace / PlayerGui instances play as-is; a ReplicatedStorage
-- template (server-mirrored from ServerStorage) is cloned into
-- SoundService once — later adopts find the clone first.
-- (Declared before adoptMusicTracks: source order matters.)
local function ensurePlayableClone(source: Sound, name: string): Sound
	local usable: Sound = source
	pcall(function()
		if source:IsDescendantOf(SoundService) or source:IsDescendantOf(Workspace) then
			return
		end
		-- NOTE: playerGui() is declared further below, so resolve
		-- PlayerGui inline here (no forward reference).
		local gui: PlayerGui? = nil
		pcall(function()
			if localPlayer ~= nil then
				gui = localPlayer:FindFirstChildOfClass('PlayerGui')
			end
		end)
		if gui ~= nil and source:IsDescendantOf(gui :: PlayerGui) then
			return
		end
		local clone = source:Clone()
		clone.Name = name
		clone.Looped = true
		clone.Parent = SoundService
		usable = clone
		logUi(('track cloned to SoundService from=%s'):format(source:GetFullName()))
	end)
	return usable
end

-- Adopt diagnosis is once per track per session (adoption
-- itself re-runs on every slider pixel — that must stay quiet).
local adoptLogged: { [string]: boolean } = {}

local function adoptMusicTracks()
	local foundAny = false
	for _, name in ipairs({ 'Bgm', 'ArenaBgm' }) do
		local source = findTrack(name)
		if source == nil then
			continue
		end
		foundAny = true
		-- Templates under ReplicatedStorage (server-mirrored from
		-- ServerStorage, which clients can never see) cannot play.
		-- Clone them into SoundService once and play the clone;
		-- later adopts find the clone first via findTrack.
		-- (Workspace tracks are respected as authored: positional.)
		local track = ensurePlayableClone(source, name)
		AudioGroups.AssignMusic(track)
		if name == 'Bgm' then
			bgmTrack = track
		else
			arenaTrack = track
		end
		-- Pin the authored base NOW (never a faded 0): adopt
		-- runs before any transition, so this sees the Studio-
		-- authored Volume. Guarded — never overwrites.
		captureBaseVolume(track)
		pcall(function()
			(track :: Sound).Looped = true
		end)
		-- Diagnosis: one line per found track per session, so the
		-- output proves adoption (path), audibility inputs
		-- (SoundId), and routing (group stamp landed or not)
		-- without spamming per slider pixel.
		if not adoptLogged[name] then
			adoptLogged[name] = true
			pcall(function()
				local t = track :: Sound
				local groupName = if t.SoundGroup ~= nil then t.SoundGroup.Name else '<none>'
				local line = ('track=%s path=%s soundId=%s volume=%.3f group=%s playing=%s'):format(
					name,
					t:GetFullName(),
					if t.SoundId == '' then '<EMPTY>' else t.SoundId,
					t.Volume,
					groupName,
					tostring(t.IsPlaying)
				)
				logUi(line)
				logMusic(('found %s'):format(line))
				if t.SoundId == '' then
					warnUi(('%s has an empty SoundId — it can never play. Set the asset ID in Studio.'):format(name))
				end
				if groupName ~= AudioGroups.BgmSoundGroupName then
					warnUi(('%s did not land in %s (group=%s) — music slider cannot control it.'):format(name, AudioGroups.BgmSoundGroupName, groupName))
				end
			end)
		end
	end
	if not foundAny then
		warnUi('no Bgm or ArenaBgm Sound found (searched SoundService, Workspace, server-mirrored ReplicatedStorage.Assets.Sfx) — place them at ServerStorage.Assets.Sfx (auto-mirrored at boot) or directly under SoundService')
	end
end

-- Thin alias kept at the original call sites (adopt the music
-- tracks). Declared after the helpers it funnels into.
local function adoptBgm()
	adoptMusicTracks()
end

-- --- GUI refs ----------------------------------------------------------

local frame: Frame? = nil
local bgmBar: GuiObject? = nil
local bgmButton: GuiButton? = nil
local bgmContainer: GuiObject? = nil
local sfxBar: GuiObject? = nil
local sfxButton: GuiButton? = nil
local sfxContainer: GuiObject? = nil
local fastButton: GuiButton? = nil
local fastText: TextLabel? = nil

local draggingBgm = false
local draggingSfx = false

local function playerGui(): PlayerGui?
	local ok, gui = pcall(function()
		if localPlayer == nil then
			return nil
		end
		return localPlayer:FindFirstChildOfClass('PlayerGui')
	end)
	if ok and gui ~= nil then
		return gui
	end
	return nil
end

local function childOf(parent: Instance?, name: string): Instance?
	if parent == nil then
		return nil
	end
	local found: Instance? = nil
	pcall(function()
		found = parent:FindFirstChild(name)
	end)
	return found
end

-- --- Persistence (debounced: release + toggle only) --------------------

local function save()
	if saveRemote == nil then
		return
	end
	pcall(function()
		(saveRemote :: RemoteEvent):FireServer({ Bgm = bgmValue, Sfx = sfxValue, FastMode = fastMode })
	end)
end

-- --- Visual paint -------------------------------------------------------

local function paintSlider(_container: GuiObject?, bar: GuiObject?, button: GuiButton?, frac: number)
	local f = math.clamp(frac, 0, 1)
	pcall(function()
		if bar ~= nil then
			local targetBar = bar :: GuiObject
			local size = targetBar.Size
			targetBar.Size = UDim2.new(f, 0, size.Y.Scale, size.Y.Offset)
		end
		if button ~= nil then
			local targetButton = button :: GuiButton
			local pos = targetButton.Position
			targetButton.Position = UDim2.new(f, 0, pos.Y.Scale, pos.Y.Offset)
		end
	end)
end

local function paintFast()
	if fastButton == nil then
		return
	end
	pcall(function()
		local button = fastButton :: GuiButton
		if fastMode then
			button.BackgroundColor3 = Color3.fromRGB(60, 200, 90)
		else
			button.BackgroundColor3 = Color3.fromRGB(200, 60, 60)
		end
		if fastText ~= nil then
			(fastText :: TextLabel).Text = if fastMode then 'ON' else 'OFF'
		end
	end)
end

-- Slider/drag path: adopt tracks, make sure the
-- mode-correct track can be heard (unmuting restarts it),
-- then snap both masters.
local function applyAudio()
	adoptBgm()
	ensureTrackPlayback()
	applyVolumes()
end

-- Fraction of the pointer across the container. Returns nil
-- while layout is not ready (AbsoluteSize 0 — e.g. touched
-- the very tick the panel opened); callers IGNORE the input
-- instead of slamming the value to 0.
local function fracFromX(container: GuiObject, x: number): number?
	local absSize = container.AbsoluteSize.X
	if absSize <= 0 then
		return nil
	end
	local absPos = container.AbsolutePosition.X
	return math.clamp((x - absPos) / absSize, 0, 1)
end

-- --- Wiring ---------------------------------------------------------------

-- Containers already wired (re-resolution must never
-- double-connect inputs).
local wiredInputs: { [Instance]: boolean } = {}

local function wireSlider(kind: string, container: GuiObject?, bar: GuiObject?, button: GuiButton?)
	if container == nil or wiredInputs[container] then
		return
	end
	wiredInputs[container] = true
	local function setFromX(x: number, commit: boolean)
		local frac = fracFromX(container :: GuiObject, x)
		if frac == nil then
			return
		end
		if kind == 'Bgm' then
			bgmValue = frac
			paintSlider(container, bar, button, frac)
			applyAudio()
		else
			sfxValue = frac
			paintSlider(container, bar, button, frac)
			applyAudio()
		end
		if commit then
			save()
		end
	end
	pcall(function()
		(container :: GuiObject).InputBegan:Connect(function(input: InputObject)
			if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
				logUi(('slider pressed kind=%s'):format(kind))
				if kind == 'Bgm' then
					draggingBgm = true
				else
					draggingSfx = true
				end
				setFromX(input.Position.X, false)
			end
		end)
	end)
	if button ~= nil then
		pcall(function()
			(button :: GuiButton).InputBegan:Connect(function(input: InputObject)
				if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
					if kind == 'Bgm' then
						draggingBgm = true
					else
						draggingSfx = true
					end
					setFromX(input.Position.X, false)
				end
			end)
		end)
	end
end

-- One-shot bindings (re-resolution updates refs but never
-- double-connects).
local closeWired = false
local fastWired = false
local visibleHooked = false
local missingWarned: { [string]: boolean } = {}

local function warnMissing(what: string)
	if missingWarned[what] then
		return
	end
	missingWarned[what] = true
	warnUi(('Settings panel piece missing: %s — check the Studio authoring names'):format(what))
end

local function ensureGui(): boolean
	local resolved = false
	pcall(function()
		local gui = playerGui()
		local main = if gui ~= nil then gui:FindFirstChild('Main') else nil
		local root = if main ~= nil then main:FindFirstChild('Settings') else nil
		if root == nil or not root:IsA('Frame') then
			return
		end
		if frame == nil then
			frame = root :: Frame
			logUi('UI found path=PlayerGui.Main.Settings')
		end
		-- Re-resolve children EVERY call: an early partial pass
		-- (frame present, rows still replicating) must not
		-- permanently wedge a slider. Wiring itself is
		-- once-per-instance (see wiredInputs).
		local scrolling = childOf(root, 'ScrollingFrame')
		if scrolling == nil then
			warnMissing('ScrollingFrame')
			return
		end
		local function section(name: string): (GuiObject?, GuiObject?, GuiButton?, GuiObject?)
			local node = childOf(scrolling, name)
			if node == nil then
				warnMissing(name)
				return nil, nil, nil, nil
			end
			local container = childOf(node, 'Container')
			local bar = childOf(container, 'Bar')
			local btn = childOf(container, 'Button')
			if container == nil then
				warnMissing(name .. '.Container')
			end
			if bar == nil then
				warnMissing(name .. '.Container.Bar')
			end
			if btn == nil then
				warnMissing(name .. '.Container.Button')
			end
			return container :: GuiObject?,
				bar :: GuiObject?,
				(if btn ~= nil and btn:IsA('GuiButton') then btn :: GuiButton else nil),
				node :: GuiObject?
		end
		local bgmContainerFound, bgmBarFound, bgmButtonFound = section('BackgroundMusic')
		bgmContainer, bgmBar, bgmButton = bgmContainerFound, bgmBarFound, bgmButtonFound
		local sfxContainerFound, sfxBarFound, sfxButtonFound = section('GameSound')
		sfxContainer, sfxBar, sfxButton = sfxContainerFound, sfxBarFound, sfxButtonFound
		local fastNode = childOf(scrolling, 'FastMode')
		if fastNode == nil then
			warnMissing('FastMode')
		end
		local fastBtn = childOf(fastNode, 'Button')
		fastButton = if fastBtn ~= nil and fastBtn:IsA('GuiButton') then fastBtn :: GuiButton else nil
		if fastButton == nil then
			warnMissing('FastMode.Button')
		end
		local fastLabel = if fastBtn ~= nil then childOf(fastBtn, 'Text') else nil
		fastText = if fastLabel ~= nil and fastLabel:IsA('TextLabel') then fastLabel :: TextLabel else nil
		local topBar = childOf(root, 'TopBar')
		local close = childOf(topBar, 'CloseButton')
		if close ~= nil and close:IsA('GuiButton') then
			if not closeWired then
				closeWired = true
				(close :: GuiButton).Activated:Connect(function()
					if frame ~= nil then
						MenuPresentation.Close(frame :: Frame)
					end
				end)
				logUi('CloseButton bound')
			end
		else
			warnMissing('TopBar.CloseButton')
		end
		if fastButton ~= nil then
			if not fastWired then
				fastWired = true
				(fastButton :: GuiButton).Activated:Connect(function()
					fastMode = not fastMode
					paintFast()
					save()
					logUi(('FastMode toggled fast=%s'):format(tostring(fastMode)))
				end)
				logUi('FastMode bound')
			end
		end
		wireSlider('Bgm', bgmContainer, bgmBar, bgmButton)
		wireSlider('Sfx', sfxContainer, sfxBar, sfxButton)
		if bgmContainer ~= nil and sfxContainer ~= nil then
			logUi('sliders bound')
			resolved = true
		end
		-- Re-resolve on every open: late-replicating rows get
		-- wired the moment the player can touch them.
		if not visibleHooked then
			visibleHooked = true
			(frame :: Frame):GetPropertyChangedSignal('Visible'):Connect(function()
				if (frame :: Frame).Visible then
					pcall(ensureGui)
				end
			end)
		end
	end)
	return resolved
end

local function applyState(state: any)
	if type(state) ~= 'table' then
		return
	end
	if type(state.Bgm) == 'number' then
		bgmValue = math.clamp(state.Bgm, 0, 1)
	end
	if type(state.Sfx) == 'number' then
		sfxValue = math.clamp(state.Sfx, 0, 1)
	end
	if type(state.FastMode) == 'boolean' then
		fastMode = state.FastMode
	end
	paintSlider(bgmContainer, bgmBar, bgmButton, bgmValue)
	paintSlider(sfxContainer, sfxBar, sfxButton, sfxValue)
	paintFast()
	-- Server push: adopt tracks, fix playback, snap masters.
	-- Saved values remain authoritative.
	adoptBgm()
	ensureTrackPlayback()
	applyVolumes()
end

function SettingsController.Init()
	if wired then
		return
	end
	wired = true
	if localPlayer == nil then
		warnUi('no LocalPlayer; controller disabled')
		return
	end
	-- UI FIRST (open/close itself is owned by the fast-boot
	-- SettingsTopbar.client.lua icon; this controller only needs
	-- the slider/toggle refs): resolve the authored
	-- PlayerGui.Main.Settings panel without waiting on remotes,
	-- profile, base, or any server system.
	pcall(function()
		if ensureGui() then
			logUi('UI ready')
		end
	end)
	-- Eager, INDEPENDENT retry: one bounded, non-blocking wait on
	-- OUR panel only so the sliders are armed even if Main
	-- replicates after startup. Single-shot.
	task.spawn(function()
		pcall(function()
			local gui = playerGui()
			if gui == nil then
				return
			end
			local main = gui:WaitForChild('Main', 5)
			if main == nil then
				return
			end
			if main:WaitForChild('Settings', 5) == nil then
				return
			end
			if ensureGui() then
				logUi('eager UI ready')
			end
			applyVolumes()
		end)
	end)
	-- Global input for slider drags (single connection; per-slider
	-- flags decide. Event-driven — no Heartbeat, no polling).
	pcall(function()
		UserInputService.InputChanged:Connect(function(input: InputObject)
			if input.UserInputType ~= Enum.UserInputType.MouseMovement and input.UserInputType ~= Enum.UserInputType.Touch then
				return
			end
			if draggingBgm and bgmContainer ~= nil then
				local frac = fracFromX(bgmContainer :: GuiObject, input.Position.X)
				if frac == nil then
					return
				end
				bgmValue = frac
				paintSlider(bgmContainer, bgmBar, bgmButton, frac)
				applyAudio()
			elseif draggingSfx and sfxContainer ~= nil then
				local frac = fracFromX(sfxContainer :: GuiObject, input.Position.X)
				if frac == nil then
					return
				end
				sfxValue = frac
				paintSlider(sfxContainer, sfxBar, sfxButton, frac)
				applyAudio()
			end
		end)
		UserInputService.InputEnded:Connect(function(input: InputObject)
			if input.UserInputType ~= Enum.UserInputType.MouseButton1 and input.UserInputType ~= Enum.UserInputType.Touch then
				return
			end
			if draggingBgm or draggingSfx then
				draggingBgm = false
				draggingSfx = false
				save()
			end
		end)
	end)
	-- Music boot (group masters, no per-sound work): adopt both
	-- tracks and snap both masters to the saved/default values.
	-- BGM plays immediately at join.
	adoptBgm()
	ensureTrackPlayback()
	applyVolumes()
	local folder = Remotes.WaitForReady()
	local okSave, saveEvent = pcall(function()
		return folder:WaitForChild(Remotes.Names.SaveSettings, 10)
	end)
	if okSave and saveEvent ~= nil and (saveEvent :: Instance):IsA('RemoteEvent') then
		saveRemote = saveEvent :: RemoteEvent
	else
		warnUi('SaveSettings remote missing; settings will not persist')
	end
	local okState, stateEvent = pcall(function()
		return folder:WaitForChild(Remotes.Names.SettingsState, 10)
	end)
	if okState and stateEvent ~= nil and (stateEvent :: Instance):IsA('RemoteEvent') then
		pcall(function()
			(stateEvent :: RemoteEvent).OnClientEvent:Connect(applyState)
		end)
	end
	-- Arena music switching (non-blocking: these slow-remote
	-- waits must never hold up Init's return or the UI above).
	-- ArenaState with Session ~= nil = raid active → ArenaBgm;
	-- RaidEnd / session-less push → back to Bgm. Both ride the
	-- same BgmSound master; exactly one track plays at a time.
	task.spawn(function()
		pcall(function()
			local arenaFolder = Remotes.WaitForReady()
			local okArena, arenaEvent = pcall(function()
				return arenaFolder:WaitForChild(Remotes.Names.ArenaState, 10)
			end)
			if okArena and arenaEvent ~= nil and (arenaEvent :: Instance):IsA('RemoteEvent') then
				(arenaEvent :: RemoteEvent).OnClientEvent:Connect(function(payload: any)
					if type(payload) ~= 'table' then
						return
					end
					-- Successful raid start ONLY: Session is present
					-- in the authoritative snapshot after
					-- StartArena validated, charged, and created
					-- the session. Menu open (Show), pre-validation
					-- clicks, and rejections carry no Session and
					-- never touch the music.
					local sess = (payload :: any).Session
					if type(sess) == 'table' then
						logMusic(
							('start event received session=%s stage=%s'):format(
								tostring(sess.SessionId),
								tostring(sess.Stage or sess.ArenaLevel)
							)
						)
						setArenaMode(true, sess.SessionId)
					else
						setArenaMode(false, nil)
					end
				end)
			end
			local okResult, resultEvent = pcall(function()
				return arenaFolder:WaitForChild(Remotes.Names.ArenaResult, 10)
			end)
			if okResult and resultEvent ~= nil and (resultEvent :: Instance):IsA('RemoteEvent') then
				(resultEvent :: RemoteEvent).OnClientEvent:Connect(function(payload: any)
					if type(payload) == 'table' and (payload :: any).Action == 'RaidEnd' then
						logMusic(('RaidEnd received session=%s'):format(tostring((payload :: any).SessionId)))
						setArenaMode(false, (payload :: any).SessionId)
					end
				end)
			end
		end)
	end)
	pcall(function()
		if ensureGui() then
			logUi('UI ready')
		end
	end)
	-- Paint current (default) values immediately so the panel is
	-- never blank before the server push lands, and snap both
	-- masters.
	paintSlider(bgmContainer, bgmBar, bgmButton, bgmValue)
	paintSlider(sfxContainer, sfxBar, sfxButton, sfxValue)
	paintFast()
	applyVolumes()
	logUi('controller ready')
end

return table.freeze(SettingsController)
