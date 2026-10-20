--!strict
--!native
--[[
	bootstrap.client
	===============
	Runs once on each client. Waits for the server to wire up the
	Remotes folder, then initialises the controllers.

	The HUD listens for PlayerState, Notify, EggArrived, and
	AnimalArrived. ToastController also subscribes to
	AnimalCarried / AnimalPlaced / EggCarried / EggPlaced
	so the wire is in place for future carry feedback (SFX,
	toast, anim) even though the current handlers are no-ops
	(PlayerState already reflects the slot's new occupancy).
	All client input is via ProximityPrompt (server-side) so
	this script does not bind to user input.

	Cmdr admin console
	------------------
	The client half of Cmdr is a ModuleScript that must be
	required on the client to register the keyboard handler,
	the GUI logic, autocomplete, and command dispatch. The
	server's CmdrBootstrap moves CmdrClient into
	ReplicatedStorage at server start (see Cmdr init.lua:
	`script.Parent.CmdrClient.Parent = ReplicatedStorage`).
	We WaitForChild it here so we don't race the replication.
	The default activation key in Cmdr 1.12.0 is F2; we leave
	it that way (the only superadmin in this project is the
	developer during Studio playtests, and F2 is the expected
	key for that workflow).
]]

local ReplicatedStorage = game:GetService('ReplicatedStorage')
local StarterGui = game:GetService('StarterGui')

local Remotes = require(ReplicatedStorage.Utility.Remotes)
-- Central debug gating (client side): syncs the canonical
-- DebugConfig into the shared Debug module so every client
-- Debug.Log / Debug.Warn obeys ClientDebug. ServerDebug never
-- enables client output. Runs before any controller Init.
local Debug = require(ReplicatedStorage.Utility.Debug)
local DebugConfig = require(ReplicatedStorage.Config.Systems.Debug)
Debug.SyncFromDebugConfig(DebugConfig)
local HUDController = require(script.Parent.HUDController)
local ToastController = require(script.Parent.ToastController)
-- Studio HUD.Notifications window (drop-in/out + spam window);
-- ToastController delegates to it when the panel exists.
local HudNotificationController = require(script.Parent.HudNotificationController)
local PromptOwnerFilter = require(script.Parent.PromptOwnerFilter)
-- Gear Shop presentation: renders server snapshots, forwards
-- purchase/autobuy actions, presents Tool previews.
local GearShopController = require(script.Parent.GearShopController)
-- Arena menu presentation: renders server snapshots,
-- forwards open/start/cancel actions. Builds its temporary
-- GUI in code (no Studio authoring needed for MVP).
local ArenaController = require(script.Parent.ArenaController)
-- Animal sell confirmation: owns the Studio-authored
-- Main.SellConfirmation template (hidden until a validated
-- server preview opens it; inert without the template).
-- Required EARLY (see Init order below): the SellPreviewState
-- subscription must exist before the Sell prompt can fire.
local SellConfirmController = require(script.Parent.SellConfirmController)
-- Arena end-of-raid results: owns the Studio-authored
-- Main.ArenaResult template (hidden until a finalized server
-- result opens it; inert without the template).
-- Required EARLY (same reason as Arena/SellConfirm): the RaidEnd
-- result must open the panel instantly, so this subscription must
-- exist before any raid can end, and it must never wait behind
-- SlotMenu's blocking MainGui resolution — it resolves
-- PlayerGui.Main.ArenaResult directly, lazily on receipt.
local ArenaResultController = require(script.Parent.ArenaResultController)
-- Arena camera impacts: centralized distance-aware hit punch
-- from the server-authoritative ArenaHit packets.
-- Presentation only (never authority); subscribes early like
-- the other Arena controllers so no impact is missed.
local ArenaCameraImpacts = require(script.Parent.ArenaCameraImpacts)
-- Arena hit bundle: instant client-local VFX + sound + damage
-- number from the single authoritative ArenaHit packet (same
-- packet the camera controller reads). Presentation only.
local ArenaHitPresentation = require(script.Parent.ArenaHitPresentation)
-- Reset gate presentation: greys out / restores the reset
-- button from the server-authoritative ResetProtection push
-- (the server owns the protected state; this only presents it).
local ResetProtectionController = require(script.Parent.ResetProtectionController)
-- Redeem codes: owns the Studio-authored Main.Codes content
-- (TextBox + Continue submit). Open/close lives in the
-- fast-boot CodesTopbar icon script, so this controller goes
-- EARLY (same reason as Arena/SellConfirm): it never waits on
-- MainGui/SlotMenuController and resolves Main.Codes directly.
local CodesController = require(script.Parent.CodesController)
-- Phase 2.9: slot interaction menus (player-facing Sell/Upgrades
-- frames; inert without the Studio-authored MainGui).
local SlotMenuController = require(script.Parent.SlotMenuController)
-- Cash-collection absorption HUD (MoneyCounter pooling
-- burst + count-up; inert without the Studio-authored HUD).
local MoneyPoolController = require(script.Parent.MoneyPoolController)
local CmdrClient = require(ReplicatedStorage:WaitForChild('CmdrClient'))

-- Block until Remotes are replicated.
Remotes.WaitForReady()

-- Removed the CoreGui blockers as they were affecting some features.
-- -- Make sure the default Roblox UI is out of our way.
-- StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.All, false)
-- -- Exception: Gear Shop Tools live in Player.Backpack and are
-- -- equipped through the default Backpack hotbar. No custom
-- -- hotbar exists anywhere in this project, so the Backpack
-- -- CoreGui must stay enabled or purchased Tools are
-- -- invisible and unequippable. Everything else stays hidden.
-- StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Backpack, true)
-- -- Exception: the TAB player list is Roblox's NATIVE CoreGui
-- -- PlayerList (fed by server-side player.leaderstats — see
-- -- TabListService). It must stay enabled: no custom player
-- -- list exists anywhere in this project by design.
-- StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.PlayerList, true)
-- StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Chat, true)

-- Init controllers. They subscribe to remotes on Init.
-- MoneyPoolController goes early (before SlotMenu's
-- blocking MainGui wait): CashCollected events must never
-- wait behind unrelated GUI resolution.
HUDController.Init()
MoneyPoolController.Init()
-- GearShopController goes early (like MoneyPoolController):
-- it must subscribe before any server push lands, and must
-- never wait behind SlotMenu's blocking MainGui resolution.
GearShopController.Init()
-- ShopController (Robux Shop open/close + buy prompts) goes
-- early for the same reason: ShopButton binding must be
-- instant and never wait on profile/base/animals/eggs.
local ShopController = require(script.Parent.ShopController)
ShopController.Init()
-- ArenaController goes early for the same reason: the
-- Adventurer prompt can fire before MainGui resolves.
ArenaController.Init()
-- CodesController goes early for the same reason: the player
-- can open Codes and submit the instant PlayerGui exists, and
-- the CodesResult subscription must exist before any result
-- can land. Never waits on server data.
CodesController.Init()
-- DailyRewardsController goes early for the same reason: the
-- player can open DailyRewards the instant PlayerGui exists,
-- and the state snapshot subscription must exist before any
-- push can land. Content (reward data) initializes
-- asynchronously afterwards via DailyRewardsState.
local DailyRewardsController = require(script.Parent.DailyRewardsController)
DailyRewardsController.Init()
-- PlaytimeRewardsController goes early for the same reason:
-- the player can open PlayTimeRewards the instant PlayerGui
-- exists, and the state subscription must exist before any
-- push can land (threshold pushes fire while closed).
-- Content initializes asynchronously via PlaytimeRewardsState.
local PlaytimeRewardsController = require(script.Parent.PlaytimeRewardsController)
PlaytimeRewardsController.Init()
-- SellConfirmController goes early for the same reason: the
-- Sell prompt can fire before MainGui resolves, and a missed
-- SellPreviewState (fired before this subscription exists)
-- is what caused the ~20s confirmation delay. This
-- controller never waits on MainGui/SlotMenuController —
-- it resolves PlayerGui.Main.SellConfirmation directly.
SellConfirmController.Init()
-- ArenaResultController goes early for the same reason: the
-- RaidEnd result must open ArenaResult instantly, before any
-- viewport/model work and before SlotMenu's blocking MainGui
-- resolution. Visible-first is owned by the controller itself.
ArenaResultController.Init()
-- Rebirth progression UI: owns the Studio-authored Main.Rebirth
-- panel (requirements/cards/bars/button). Resolves lazily and
-- degrades without the template; never blocks other controllers.
-- Required EARLY (same reason as SellConfirm): the HUD toggle
-- must bind before SlotMenuController's blocking MainGui wait —
-- opening the panel is local UI and never waits on server data.
local RebirthController = require(script.Parent.RebirthController)
RebirthController.Init()
-- Server-authoritative egg guarantee timers
-- (Map.CenterPart.BillboardGui.Egg attributes, legacy
-- Workspace.Map.EggTimer fallback; local countdown only,
-- never decides spawns). Resolves lazily, never blocks.
local EggTimerController = require(script.Parent.EggTimerController)
EggTimerController.Init()
-- World-event countdown (Map.CenterPart.BillboardGui.Event
-- TextLabel; local countdown from server timestamps only,
-- never decides events). Resolves lazily, never blocks.
local EventController = require(script.Parent.EventController)
EventController.Init()
-- Server-authoritative event start/stop transition cinematic
-- (FOV zoom + white flash + fade, broadcast to every client).
-- Early like EventController: the subscription must exist
-- before any transition can land, and it never waits on
-- server data or other controllers.
local EventTransitionController = require(script.Parent.EventTransitionController)
EventTransitionController.Init()
-- Server-authoritative luck display (ReplicatedStorage
-- ServerLuck attribute; display only, never decides rolls).
-- Resolves lazily, never blocks.
local ServerLuckController = require(script.Parent.ServerLuckController)
ServerLuckController.Init()
-- Tutorial guide layer presentation (server-authoritative
-- steps; arrow/highlight/overlay only, never progression).
-- Early like the other visual controllers: must subscribe
-- before any server push lands and never wait behind
-- SlotMenu's blocking MainGui resolution.
local TutorialController = require(script.Parent.TutorialController)
TutorialController.Init()
ArenaCameraImpacts.Init()
ArenaHitPresentation.Init()
HudNotificationController.Init()
ToastController.Init()
-- Personal UI sounds (UiHover/UiClick on every button via
-- MouseEnter/Activated, UiOpen via MenuPresentation): local
-- PlayerGui clones only — each player hears only their own
-- UI. Early so hover/click feedback exists from first paint;
-- late-streamed buttons wire through DescendantAdded.
local UiSoundController = require(script.Parent.UiSoundController)
UiSoundController.Init()
-- Client settings (authored Main.Settings panel + BGM/SFX
-- masters + persisted preferences + music tracks). Goes BEFORE
-- SlotMenuController: SlotMenu's Init blocks ~15s on its
-- MainGui wait, and Settings (sliders + music adopt/play) must
-- not sit behind it. Settings depends on no other controller
-- and nothing depends on it, so this reorder is safe.
local SettingsController = require(script.Parent.SettingsController)
SettingsController.Init()
SlotMenuController.Init()
-- PromptOwnerFilter: multi-player prompt visibility filter
-- (hides Pickup/Open/Place prompts whose ownerUserId /
-- targetUserId doesn't match the local player; also hides
-- every Buy prompt while the local player is carrying).
PromptOwnerFilter.Init()
-- Server-authoritative reset gate presentation (subscribes to
-- the ResetProtection push; no input binding here).
ResetProtectionController.Init()
-- Thief-only steal camera presentation (subscribes to the
-- per-player PlayerState carry flag; thief + animal only —
-- ownership/transfer/slowdown stay server-side).
local StealPresentationController = require(script.Parent.StealPresentationController)
StealPresentationController.Init()
-- Carry tool lock presentation (subscribes to the CarryLock
-- push; Backpack/hotbar prevention only — the server enforces).
local ToolLockController = require(script.Parent.ToolLockController)
ToolLockController.Init()
-- Bat PvP input: instant local swing animation + swing request.
-- The server decides everything else; this never claims a hit.
local BatController = require(script.Parent.BatController)
BatController.Init()
-- CmdrClient was already required at the top of this file
-- (so the require happens before any HUDController work that
-- could be intercepted by Cmdr hooks). Referencing the local
-- here documents that the activation is deliberate; the module
-- is cached, so this is a no-op.
local _ = CmdrClient

print('[bootstrap.client] Client initialised, awaiting server state.')
