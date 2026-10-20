--!strict
--[[
	ClientPresentation — client-side tunables
	========================================

	CONSOLIDATED VIEW of every tunable the client layer reads or owns.

	WHY THIS FILE EXISTS
	--------------------
	The client layer is split across two kinds of tunable:

	1. TUNABLES THAT LIVE IN CANONICAL CONFIG MODULES
	   (e.g. Config.Presentation.UI.Notify.HudMotion). Those are owned by
	   other systems in this library and MUST be tuned there. This file
	   does NOT duplicate their values — it only points at them, and it
	   records the ones the client actually consumes so you can find
	   them in one place.

	2. TUNABLES THAT LIVE AS LITERALS INSIDE THE CLIENT SCRIPTS
	   (e.g. MenuPresentation's DIM_TARGET_TRANSPARENCY = 0.55).
	   These are the ones that would otherwise be invisible: they are
	   scattered across 35 files with no index. The `Client` table below
	   consolidates them, with the default, the meaning, the valid
	   range, whether it is safe to change, which module reads it, and
	   whether it is a placeholder.

	IMPORTANT
	---------
	Nothing in this file is *required* by the shipped client scripts.
	They still carry their own literals. This module is a **reference
	and a landing pad**: to change a value, edit the owning module (or
	edit the literal in the owning script) and then update the matching
	entry here so the index stays truthful.

	A "placeholder" is a value that is deliberately a stand-in — a
	placeholder asset id, a magic number that exists only because the
	real one is authored elsewhere, or a default that is expected to be
	overridden by a Studio asset. Placeholders are marked explicitly
	below.

	Reading this file gives you the whole client tuning surface in one
	place. It is documentation-grade, and it is safe to require from
	Studio for inspection.
]]

local Config = {}

-- ---------------------------------------------------------------------------
-- 1. TUNABLES OWNED BY OTHER SYSTEMS (canonical homes)
-- ---------------------------------------------------------------------------
-- The client reads these from the modules listed. Edit THERE, not here.
-- Listed so a new game knows exactly which config modules its client
-- layer depends on.

Config.External = {
	-- Config.Presentation.UI.Notify.HudMotion — read by
	-- HudNotificationController (DisplayDuration, EnterOffsetPx,
	-- ExitOffsetPx, DropSeconds, ExitSeconds, ExitCancelSeconds,
	-- ExitCancelDelaySeconds, RestoreBufferSeconds).
	-- Safe to change: yes. Presentation only.
	UI_Notify_HudMotion = 'ReplicatedStorage.Config.Presentation.UI.Notify.HudMotion',

	-- Config.Presentation.UI.Notify.CategoryColor — read by
	-- HudNotificationController (per-notification accent colour).
	-- Safe to change: yes. Presentation only.
	UI_Notify_CategoryColor = 'ReplicatedStorage.Config.Presentation.UI.Notify.CategoryColor',

	-- Config.Presentation.UI.Notify.MaxTextLength (120) — read by
	-- HudNotificationController / ToastController for truncation.
	-- Safe to change: yes.
	UI_Notify_MaxTextLength = 'ReplicatedStorage.Config.Presentation.UI.Notify.MaxTextLength',

	-- Config.Presentation.UI.Notify.DefaultDuration (4) — read by
	-- ToastController for the auto-dismiss timer.
	-- Safe to change: yes.
	UI_Notify_DefaultDuration = 'ReplicatedStorage.Config.Presentation.UI.Notify.DefaultDuration',

	-- Config.World.ArenaFeel.CameraShake — read by
	-- ArenaCameraImpacts (FullRange 15, MaxRange 30, Duration 0.28,
	-- MaxPosition 0.18, MaxRotation 0.012).
	-- Safe to change: yes. Presentation only; the server never reads it.
	ArenaFeel_CameraShake = 'ReplicatedStorage.Config.World.ArenaFeel.CameraShake',

	-- Config.World.ArenaFeel.DamageNumber — read by
	-- ArenaHitPresentation (pop/settle/exit scales, durations, colours,
	-- cull distance). Safe to change: yes.
	ArenaFeel_DamageNumber = 'ReplicatedStorage.Config.World.ArenaFeel.DamageNumber',

	-- Config.World.ArenaFeel.Vfx / .Sfx / .Anchor — read by
	-- ArenaHitPresentation (asset key, emit fallback, cleanup clamps,
	-- anchor size/lifetime). Safe to change: yes.
	ArenaFeel_Vfx_Sfx_Anchor = 'ReplicatedStorage.Config.World.ArenaFeel.{Vfx,Sfx,Anchor}',

	-- Config.World.Stealing.StealPresentation — read by
	-- StealPresentationController (FOVMultiplier 0.9, FOVTweenTime 0.3).
	-- Safe to change: yes, but the multiplier MUST stay in (0, 1) or
	-- the camera zooms OUT during a steal. The config validator enforces
	-- this.
	Stealing_StealPresentation = 'ReplicatedStorage.Config.World.Stealing.StealPresentation',

	-- Config.World.Bases.MoneyPool — read by MoneyPoolController
	-- (icon sizing, flight timing, burst radius, bop durations, number
	-- steps). Safe to change: yes. Presentation only.
	Bases_MoneyPool = 'ReplicatedStorage.Config.World.Bases.MoneyPool',

	-- Config.Economy.Sell — read by SellConfirmController
	-- (ResultTimeout, RarityGradient.LightenT / DarkenT, and the
	-- Viewport.* showcase camera set). Safe to change: yes.
	Sell = 'ReplicatedStorage.Config.Economy.Sell',

	-- Config.Creatures.Rarity — read by ArenaResultController,
	-- HUDController, RebirthController, SellConfirmController for
	-- rarity colours. Safe to change: yes, but rarity colours are
	-- shared with the server; change them in RarityConfig.
	Rarity = 'ReplicatedStorage.Config.Creatures.Rarity',

	-- Config.Creatures.Traits — read by SellConfirmController to render
	-- the trait line. Safe to change: yes.
	Traits = 'ReplicatedStorage.Config.Creatures.Traits',

	-- Config.Creatures.Eggs — read by EggTimerController and
	-- TutorialController for egg names/ids. Changing an egg id breaks
	-- the tutorial's per-player tag mapping. Change with care.
	Eggs = 'ReplicatedStorage.Config.Creatures.Eggs',

	-- Config.World.Events — read by EventController and
	-- EventTransitionController for event ids and window times.
	-- Safe to change: yes, but the server reads the same table.
	Events = 'ReplicatedStorage.Config.World.Events',

	-- Config.Economy.Shop — read by ShopController, DailyRewardsController
	-- and PlaytimeRewardsController for gamepass/product ids and
	-- price text. Changing a product id breaks purchases — change with
	-- care.
	Shop = 'ReplicatedStorage.Config.Economy.Shop',

	-- Config.Economy.Gear.Combat — read by BatController for the gear
	-- combat profile. Server-authoritative values; the client only
	-- reads presentation-relevant fields.
	Gear_Combat = 'ReplicatedStorage.Config.Economy.Gear.Combat',

	-- Config.Systems.Debug — read by bootstrap.client.lua
	-- (ClientDebug, Tags, Subsystem.ArenaHitClient, Audio.Enabled).
	-- Safe to change: yes. ClientDebug gates ALL Debug.Log output.
	Debug = 'ReplicatedStorage.Config.Systems.Debug',
}

-- ---------------------------------------------------------------------------
-- 2. TUNABLES THE CLIENT OWNS (currently literals inside the scripts)
-- ---------------------------------------------------------------------------
-- Each entry: the value the shipped script uses today, where it lives, and
-- who reads it. "Safe to change" is about breaking *other* systems, not
-- about breaking the client.

Config.Client = {}

-- --- MenuPresentation (menu chrome: dim overlay + blur) --------------------

Config.Client.Menu = {
	-- DisplayOrder of the singleton `MenuDimGui` overlay.
	-- Default: -10. Meaning: the dim sits behind every menu (which are
	-- at the default order). Valid range: any integer below your menu's
	-- order. Safe to change: yes. Read by: MenuPresentation.
	-- Placeholder: no.
	DimDisplayOrder = -10,

	-- Target transparency of the dim `Frame` when a menu is open.
	-- Default: 0.55. Meaning: how dark the screen goes behind a menu.
	-- Valid range: 0 (fully opaque black) .. 1 (invisible).
	-- Safe to change: yes. Read by: MenuPresentation.
	-- Placeholder: no.
	DimTargetTransparency = 0.55,

	-- Target `BlurEffect.Size` when a menu is open.
	-- Default: 8. Meaning: blur strength behind a menu.
	-- Valid range: 0 .. 64. Safe to change: yes.
	-- Read by: MenuPresentation. Placeholder: no.
	BlurTargetSize = 8,

	-- Duration of the dim/blur fade in and out.
	-- Default: 0.25 seconds. Meaning: how fast the chrome appears.
	-- Valid range: > 0. Safe to change: yes. Read by: MenuPresentation.
	-- Placeholder: no.
	ChromeTweenSeconds = 0.25,
}

-- --- Notification / toast ---------------------------------------------------

Config.Client.Notify = {
	-- Hard cap on notification text length.
	-- Default: 120 characters. Meaning: truncates runaway server text.
	-- Valid range: > 0. Safe to change: yes.
	-- Read by: HudNotificationController, ToastController.
	-- Placeholder: no. (The canonical home is
	-- Config.Presentation.UI.Notify.MaxTextLength, which is 120 too —
	-- the client currently hardcodes its own copy.)
	MaxTextLength = 120,
}

-- --- Poll cadences (event-driven where possible) ---------------------------

Config.Client.Poll = {
	-- Egg-timer HUD repaint interval.
	-- Default: 0.25 seconds (4 Hz). Meaning: how often the egg
	-- guarantee countdown re-renders. Valid range: > 0.
	-- Safe to change: yes, but every 4 Hz tick on every player is a
	-- per-frame cost. Read by: EggTimerController.
	-- Placeholder: no.
	EggTimerRepaintInterval = 0.25,

	-- Event countdown HUD repaint interval.
	-- Default: 0.25 seconds (4 Hz). Meaning: how often the event
	-- countdown re-renders. Valid range: > 0. Safe to change: yes.
	-- Read by: EventController. Placeholder: no.
	EventRepaintInterval = 0.25,

	-- ProximityPrompt visibility filter tick.
	-- Default: 0.25 seconds (4 Hz). Meaning: how often the filter
	-- re-evaluates every prompt in the workspace against
	-- `PlayerState`. Valid range: > 0. Safe to change: yes, but it
	-- is a workspace-wide scan — raising it makes prompts visibly
	-- stale. Read by: PromptOwnerFilter. Placeholder: no.
	PromptFilterTick = 0.25,

	-- Full prompt resync interval.
	-- Default: 5 seconds. Meaning: how often the filter forces a
	-- complete re-scan even if nothing changed. Valid range: > 0.
	-- Safe to change: yes. Read by: PromptOwnerFilter.
	-- Placeholder: no.
	PromptFilterResync = 5,
}

-- --- Waits / backstops ------------------------------------------------------

Config.Client.Wait = {
	-- How long a controller waits for its Studio-authored panel before
	-- giving up (and degrading).
	-- Default: 10 seconds. Meaning: the max time a controller blocks
	-- on `PlayerGui.Main.<Panel>`. Valid range: > 0.
	-- Safe to change: yes, but a shorter wait means a late-replicating
	-- panel is abandoned. Read by: ShopController, and the four
	-- topbar LocalScripts. Placeholder: no.
	MainPanelWait = 10,

	-- How long a controller waits for the PlayerGui itself.
	-- Default: 10 seconds. Valid range: > 0. Safe to change: yes.
	-- Read by: ShopController, topbar LocalScripts. Placeholder: no.
	PlayerGuiWait = 10,

	-- How long a controller waits for `ReplicatedStorage.Packages`.
	-- Default: 10 seconds. Valid range: > 0. Safe to change: yes.
	-- Read by: the four topbar LocalScripts. Placeholder: no.
	PackagesWait = 10,

	-- "Eager" first-paint wait for the main panel / its template, in
	-- the data-heavy controllers. The panel binds from `PlayerGui`
	-- alone first; this is only how long it waits for the *template*
	-- to replicate before rendering rows.
	-- Default: 5 seconds (panel) / 3 seconds (template).
	-- Valid range: > 0. Safe to change: yes.
	-- Read by: ArenaResultController, RebirthController,
	-- SellConfirmController. Placeholder: no.
	EagerMainWait = 5,
	EagerTemplateWait = 3,

	-- Claim backstop: how long a rewards controller waits for the
	-- server's claim result before re-enabling its button.
	-- Default: 5 seconds. Meaning: if the result never arrives, the
	-- button unlocks anyway so the player is not stuck. Valid range: > 0.
	-- Safe to change: yes.
	-- Read by: DailyRewardsController, PlaytimeRewardsController,
	-- CodesController. Placeholder: no.
	ClaimBackstop = 5,

	-- Sell-confirm result timeout: how long the sell panel waits for
	-- `SellConfirmResult` before closing itself.
	-- Default: read from `Config.Economy.Sell.ResultTimeout`.
	-- Safe to change: yes, but it must exceed the server's worst-case
	-- processing time or the client closes a panel whose sale
	-- succeeded. Read by: SellConfirmController. Placeholder: no.
	SellResultTimeout = 'Config.Economy.Sell.ResultTimeout',
}

-- --- Topbar icons (fast-boot LocalScripts) ---------------------------------

Config.Client.Topbar = {
	-- Icon name registered with TopbarPlus.
	-- Defaults: 'Settings' / 'Codes' / 'DailyRewards' / 'PlaytimeRewards'.
	-- Meaning: the key TopbarPlus uses to look up / persist the icon.
	-- Valid range: any non-empty string. Safe to change: yes, but a
	-- changed name loses the player's saved icon position.
	-- Read by: SettingsTopbar.client, CodesTopbar.client,
	-- DailyTopbar.client, PlaytimeTopbar.client. Placeholder: no.
	IconNames = {
		Settings = 'Settings',
		Codes = 'Codes',
		DailyRewards = 'DailyRewards',
		PlaytimeRewards = 'PlaytimeRewards',
	},

	-- Image asset id shown on the icon.
	-- Defaults: 10734950309 / 10734983868 / 10709789505 / 10709805144.
	-- Meaning: the `Image` on the TopbarPlus icon.
	-- Valid range: a valid Roblox asset id. Safe to change: yes, but
	-- the asset must be uploaded by the publisher and readable.
	-- Read by: the four topbar LocalScripts.
	-- Placeholder: YES — these are the source game's own icon
	-- uploads. A new game MUST replace them with its own assets.
	ImageIds = {
		Settings = 10734950309,
		Codes = 10734983868,
		DailyRewards = 10709789505,
		PlaytimeRewards = 10709805144,
	},
}

-- --- Misc presentation ------------------------------------------------------

Config.Client.Misc = {
	-- Server-luck text shown before the server has pushed a value.
	-- Default: '1.0x'. Meaning: the HUD fallback. Valid range: any
	-- string. Safe to change: yes. Read by: ServerLuckController.
	-- Placeholder: YES — it is a neutral display default, not a real
	-- multiplier.
	ServerLuckDefaultText = '1.0x',

	-- Attribute on `ReplicatedStorage` that carries the server luck.
	-- Default: 'ServerLuck'. Meaning: where the value is read from.
	-- Valid range: any attribute name. Safe to change: no — the
	-- SERVER writes this exact attribute name. Read by:
	-- ServerLuckController. Placeholder: no.
	ServerLuckAttribute = 'ServerLuck',

	-- CollectionService tag prefix used to mark the tutorial target.
	-- Default: 'TutorialTarget'. Meaning: the tag is
	-- `TutorialTarget_<userId>`. Valid range: any string.
	-- Safe to change: no — the SERVER sets the tag. Read by:
	-- TutorialController. Placeholder: no.
	TutorialTagPrefix = 'TutorialTarget',

	-- Name of the replicated beam template used by the tutorial
	-- spotlight. Default: 'TutorialBeamTemplate'. Meaning: the
	-- `ReplicatedStorage` instance name. Valid range: any string.
	-- Safe to change: no — the SERVER mirrors the asset under this
	-- name. Read by: TutorialController. Placeholder: no.
	TutorialBeamTemplateName = 'TutorialBeamTemplate',

	-- Bat swing animation asset id.
	-- Default: 'rbxassetid://79224347193775'. Meaning: the animation
	-- played on the local bat tool. Valid range: a valid animation id.
	-- Safe to change: yes, but the animation must be a bat swing.
	-- Read by: BatController. Placeholder: YES — the source game's
	-- own animation upload. Replace it.
	BatSwingAnimationId = 'rbxassetid://79224347193775',

	-- Delay between tutorial UI "beats" (the pacing between the
	-- spotlight step and the next prompt).
	-- Default: 2.5 seconds. Meaning: how long the tutorial lingers on
	-- each step. Valid range: > 0. Safe to change: yes.
	-- Read by: TutorialController. Placeholder: no.
	TutorialUiBeatDelay = 2.5,

	-- Crossfade duration when switching between lobby and arena music.
	-- Default: 1.0 seconds per leg (out, then in).
	-- Meaning: the music transition length. Valid range: > 0.
	-- Safe to change: yes. Read by: SettingsController.
	-- Placeholder: no.
	ArenaMusicFadeSeconds = 1.0,

	-- Folder under `ReplicatedStorage` holding the per-gear preview
	-- models. Default: 'GearShopPreviews'. Meaning: where the gear shop
	-- and rebirth gear cards get their 3D models. Valid range: any
	-- string. Safe to change: no — the SERVER mirrors the models
	-- under this name. Read by: GearShopController, RebirthController.
	-- Placeholder: no.
	GearPreviewFolder = 'GearShopPreviews',
}

-- ---------------------------------------------------------------------------
-- 3. VALIDATION
-- ---------------------------------------------------------------------------
-- Mirrors the style of the canonical config modules in this library, so a
-- config validator can call it the same way.

function Config.Validate(): { string }
	local issues: { string } = {}

	local function num(path: string, v: any, min: number)
		if type(v) ~= 'number' or v ~= v or v < min then
			issues[#issues + 1] = path .. ' must be a number >= ' .. tostring(min)
		end
	end

	num('Client.Menu.DimTargetTransparency', Config.Client.Menu.DimTargetTransparency, 0)
	if Config.Client.Menu.DimTargetTransparency > 1 then
		issues[#issues + 1] = 'Client.Menu.DimTargetTransparency must be <= 1'
	end
	num('Client.Menu.BlurTargetSize', Config.Client.Menu.BlurTargetSize, 0)
	num('Client.Menu.ChromeTweenSeconds', Config.Client.Menu.ChromeTweenSeconds, 0.001)
	num('Client.Notify.MaxTextLength', Config.Client.Notify.MaxTextLength, 1)
	num('Client.Poll.EggTimerRepaintInterval', Config.Client.Poll.EggTimerRepaintInterval, 0.001)
	num('Client.Poll.EventRepaintInterval', Config.Client.Poll.EventRepaintInterval, 0.001)
	num('Client.Poll.PromptFilterTick', Config.Client.Poll.PromptFilterTick, 0.001)
	num('Client.Poll.PromptFilterResync', Config.Client.Poll.PromptFilterResync, 0.001)
	num('Client.Wait.MainPanelWait', Config.Client.Wait.MainPanelWait, 0.001)
	num('Client.Wait.PlayerGuiWait', Config.Client.Wait.PlayerGuiWait, 0.001)
	num('Client.Wait.PackagesWait', Config.Client.Wait.PackagesWait, 0.001)
	num('Client.Wait.EagerMainWait', Config.Client.Wait.EagerMainWait, 0.001)
	num('Client.Wait.EagerTemplateWait', Config.Client.Wait.EagerTemplateWait, 0.001)
	num('Client.Wait.ClaimBackstop', Config.Client.Wait.ClaimBackstop, 0.001)
	num('Client.Misc.ArenaMusicFadeSeconds', Config.Client.Misc.ArenaMusicFadeSeconds, 0.001)
	num('Client.Misc.TutorialUiBeatDelay', Config.Client.Misc.TutorialUiBeatDelay, 0.001)

	return issues
end

table.freeze(Config.Client.Menu)
table.freeze(Config.Client.Notify)
table.freeze(Config.Client.Poll)
table.freeze(Config.Client.Wait)
table.freeze(Config.Client.Misc)
table.freeze(Config.Client.Topbar.IconNames)
table.freeze(Config.Client.Topbar.ImageIds)
table.freeze(Config.Client.Topbar)
table.freeze(Config.Client)
table.freeze(Config.External)

return table.freeze(Config)
