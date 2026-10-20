--!strict
--[[
	CANONICAL CONFIG (unified architecture).
	Single source of truth for its domain. New code must require this path.
	Values preserved exactly from the pre-migration configs - do NOT rebalance
	without a gameplay review. See Docs/configuration/ for domain docs.
]]
-- UI: HUD/toast tokens (root), toast timing (UI.Notify), animal overheads (UI.Overhead).
-- Presentation only: safe to tune freely, never gates gameplay correctness.
local Rarity = require(script.Parent.Parent.Creatures.Rarity)
--[[
	UI
	========
	Tokens used by the client-side HUD + Toast controllers. Designers
	can recolor / resize / reposition without touching client code.
]]

local UI = {}

UI.RarityColor = Rarity.RarityColor

-- Font tokens. Roblox ships a few safe choices; we centralise them
-- so the same face is used everywhere.
UI.Font = {
	Heading = Enum.Font.GothamBold,
	Body = Enum.Font.GothamMedium,
	Number = Enum.Font.GothamBold,
}

UI.TextSize = {
	H1 = 28,
	H2 = 22,
	Body = 16,
	Small = 13,
}

-- Backgrounds and accents.
UI.Color = {
	Background = Color3.fromRGB(20, 20, 30),
	Panel = Color3.fromRGB(35, 35, 50),
	PanelBorder = Color3.fromRGB(80, 80, 100),
	Text = Color3.fromRGB(240, 240, 250),
	TextMuted = Color3.fromRGB(180, 180, 200),
	Accent = Color3.fromRGB(120, 200, 255),
	Success = Color3.fromRGB(100, 220, 130),
	Warning = Color3.fromRGB(255, 200, 80),
	Error = Color3.fromRGB(255, 90, 90),
}

-- HUD layout: top-left, fixed size, padded.
UI.HUD = {
	Anchor = Vector2.new(0, 0),
	Position = UDim2.fromOffset(16, 16),
	Size = UDim2.fromOffset(280, 200),
	Padding = 8,
}

-- Slot row sizing inside the HUD.
UI.SlotRow = {
	Width = 248,
	Height = 28,
	Gap = 4,
}

-- Toast (notification) sizing.
UI.Toast = {
	Width = 320,
	Height = 56,
	MaxVisible = 3,
	StackGap = 6,
	Anchor = Vector2.new(1, 1), -- bottom-right
	StackOrigin = UDim2.new(1, -16, 1, -16),
}

-- --- Toast timing/behavior (former NotificationConfig) ---
UI.Notify = {}
--[[
	UI.Notify
	==================
	Tunables for the client-side toast system.

	Spec §48-§52.
]]

-- How long a toast sits on screen before auto-dismissing.
UI.Notify.DefaultDuration = 4

-- A new toast with the same (Category, Text) arriving within this
-- many seconds is coalesced into the existing one (its lifetime is
-- extended instead of stacking). Spec §51.
UI.Notify.CoalesceWindow = 1.5

-- Hard cap on text length to keep toasts from overflowing.
UI.Notify.MaxTextLength = 120

-- Categories. Server picks one when calling Notify; client uses
-- it to choose the accent color.
UI.Notify.Category = {
	System = 'System', -- game-state messages
	Reward = 'Reward', -- positive (bought an egg, got an animal)
	Warning = 'Warning', -- recoverable problem (insufficient cash)
	Error = 'Error', -- unrecoverable (server kicked you)
}

-- Per-category accent colors.
UI.Notify.CategoryColor = {
	System = Color3.fromRGB(160, 200, 255),
	Reward = Color3.fromRGB(120, 230, 140),
	Warning = Color3.fromRGB(255, 200, 80),
	Error = Color3.fromRGB(255, 90, 90),
}

-- --- Motion specs (client presentation) -----------------------------------
-- Added by the configuration pass; values preserved exactly from the
-- controllers' locals. Presentation only: safe to tune freely.

-- HudNotificationController window motion: single ease in/out, no
-- overshoot. Offsets are Y-only pixels; durations seconds.
UI.Notify.HudMotion = {
	DisplayDuration = 2.0,
	EnterOffsetPx = 64,
	ExitOffsetPx = 60,
	DropSeconds = 0.25,
	ExitSeconds = 0.2,
	-- Exit-cancel ease (interrupted exit snaps back to resting).
	ExitCancelSeconds = 0.18,
	ExitCancelDelaySeconds = 0.23,
	-- Scheduling buffer after tween/restore delays (expiry, exit,
	-- enter-restore). Keeps restores behind the tween that precedes them.
	RestoreBufferSeconds = 0.05,
}

-- ToastController enter/exit tweens (Quad Out). Seconds.
UI.Notify.ToastMotion = {
	EnterSeconds = 0.12,
	ExitSeconds = 0.15,
}

-- --- Animal overhead billboards (former OverheadConfig) ---
UI.Overhead = {}
--[[
	UI.Overhead
	==============
	Single source of truth for animal overhead billboard PRESENTATION:
	trait colors, rainbow animation, and the shared fallback color.

	WHAT THIS CONTROLS
	------------------
	How floating nameplates look. Rarity colors stay canonical in
	RarityConfig (this module READS them, never duplicates); only the
	trait-specific presentation mapping lives here, because
	TraitConfig carries multipliers only (by design — data vs style).

	ARCHITECTURE NOTES (do not regress)
	-----------------------------------
	* Event-driven: overheads refresh on committed change feeds.
	  NEVER add per-Animal Heartbeat polling to tune these.
	* The Rainbow controller is ONE shared server Heartbeat for every
	  Rainbow overhead (never per-animal). Period + stops are tunable
	  here; the sharing mechanism stays code-owned.
	* Sheen gradients derive white->color on the CLONE's authored
	  UIGradient; Studio templates are never touched.
]]

-- Trait presentation colors. Gold reuses the canonical Legendary
-- gold; Diamond is ice-cyan. Rainbow is animated (below), never
-- static. Type: Color3 each. Presentation only.
UI.Overhead.TraitColors = {
	Gold = Color3.fromRGB(245, 200, 70),
	Diamond = Color3.fromRGB(150, 225, 255),
}

-- Mutation presentation colors (same data-vs-style split as
-- traits: MutationConfig carries multipliers only). Used by
-- overhead-adjacent text (event mutation toasts) and available
-- to any future mutation-tinted UI. Galactic reads cosmic
-- purple; Frost reads ice blue. Type: Color3 each.
UI.Overhead.MutationColors = {
	Galactic = Color3.fromRGB(168, 85, 247),
	Frost = Color3.fromRGB(147, 197, 253),
}

-- Fallback when a rarity color lookup fails. Type: Color3.
-- CURRENT: white (255, 255, 255).
UI.Overhead.FallbackColor = Color3.fromRGB(255, 255, 255)

-- Stolen-animal name color while steal-carried. Matches the
-- game's existing danger red (RichTextFormatter.DangerHex
-- #FF5A5A = 255, 90, 90) so robbery copy and the overhead
-- agree. Type: Color3. Presentation only.
UI.Overhead.StolenTextColor = Color3.fromRGB(255, 90, 90)

-- --- Rainbow animation (shared single-Heartbeat controller) ---------------------

UI.Overhead.Rainbow = {
	-- Full cycle time. Type: number. Unit: seconds. Valid: > 0.
	-- CURRENT: 3. Decrease: faster shimmer. Increase: slow drift.
	Period = 3,
	-- Gradient stops (must start and end on the same color so the
	-- wrap is seamless). CURRENT: red->orange->yellow->green->
	-- blue->purple->red.
	Stops = {
		{ At = 0, Color = Color3.fromRGB(255, 0, 0) },
		{ At = 0.17, Color = Color3.fromRGB(255, 140, 0) },
		{ At = 0.33, Color = Color3.fromRGB(255, 235, 0) },
		{ At = 0.5, Color = Color3.fromRGB(0, 200, 80) },
		{ At = 0.67, Color = Color3.fromRGB(0, 140, 255) },
		{ At = 0.83, Color = Color3.fromRGB(150, 60, 255) },
		{ At = 1, Color = Color3.fromRGB(255, 0, 0) },
	},
	-- UIStroke rainbow uses HSV(t, Saturation, Value) per tick.
	-- CURRENT: 0.9 / 1.
	StrokeSaturation = 0.9,
	StrokeValue = 1,
}

function UI.Overhead.Validate(): { string }
	local issues: { string } = {}
	if typeof(UI.Overhead.TraitColors.Gold) ~= 'Color3' then
		issues[#issues + 1] = 'TraitColors.Gold must be a Color3'
	end
	if typeof(UI.Overhead.TraitColors.Diamond) ~= 'Color3' then
		issues[#issues + 1] = 'TraitColors.Diamond must be a Color3'
	end
	if typeof(UI.Overhead.MutationColors.Galactic) ~= 'Color3' then
		issues[#issues + 1] = 'MutationColors.Galactic must be a Color3'
	end
	if typeof(UI.Overhead.MutationColors.Frost) ~= 'Color3' then
		issues[#issues + 1] = 'MutationColors.Frost must be a Color3'
	end
	if typeof(UI.Overhead.FallbackColor) ~= 'Color3' then
		issues[#issues + 1] = 'FallbackColor must be a Color3'
	end
	if typeof(UI.Overhead.StolenTextColor) ~= 'Color3' then
		issues[#issues + 1] = 'StolenTextColor must be a Color3'
	end
	if type(UI.Overhead.Rainbow.Period) ~= 'number' or UI.Overhead.Rainbow.Period <= 0 then
		issues[#issues + 1] = 'Rainbow.Period must be a number > 0'
	end
	return issues
end

table.freeze(UI.Notify)
table.freeze(UI.Overhead)

return table.freeze(UI)
