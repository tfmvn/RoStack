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
	Sell
	==========
	Single source of truth for the sell-confirmation flow's TUNABLE
	values: viewport staging/framing, rarity-gradient shading,
	preview scale, result timeout, and confirmation labels.

	WHAT THIS CONTROLS
	------------------
	How the "Sell for $X?" confirmation LOOKS. The pending-sale
	generation/token validation (anti-exploit) stays code-owned in
	SellService + SlotActionHandler — this module never touches it.

	WHAT THIS DOES NOT CONTROL
	--------------------------
	* Sale VALUES (SellService canonical calc). This module's labels
	  only FORMAT the authoritative number.
	* Whether an egg can be sold (it can't — structural rule).
	* Remote names, token shape, pending-sale lifecycle.

	All values below are the CANONICAL sell-preview tunables (unified config
migration: the forked SellConfirmController locals were reconciled HERE and
	the controller now reads this module). Presentation only: safe to tune
	freely. Never clone real Animals — the controller previews a scale-only
	clone; that rule stays in code.
]]

local Sell = {}

-- --- Viewport staging ---------------------------------------------------------

Sell.Viewport = {
	-- Stage origin: the preview clone's pivot placement + yaw.
	-- The authored Orientation pitch is deliberately NOT applied
	-- (it would tip the animal face-down); only yaw stages it.
	-- CURRENT: (20.263, 120.066, 20.066) / yaw -31.716deg.
	OriginPosition = Vector3.new(20.263, 120.066, 20.066),
	OriginOrientationDeg = Vector3.new(0, -31.716, 0),
	-- Preview clone renders 1.25x about its bbox center.
	-- Viewport-only; the live animal keeps exact scale.
	-- Type: number > 0. CURRENT: 1.25.
	PreviewScale = 1.25,
	-- Fit margin: bbox corners may approach frame edges while face
	-- centers stay inside. Back toward 1.15 if extremities touch;
	-- never below 1.0 (reintroduces loose framing). CURRENT: 1.1
	-- (canonical live value; the AnimalViewport path reads this).
	ShowcaseMargin = 1.1,
	-- Zoom factor. CURRENT: 0.7 (canonical live value).
	ShowcaseZoom = 0.7,
	-- Camera yaw off the model's facing: mid-side front-profile
	-- close-up (face + one side, upright). CURRENT: 25 degrees
	-- (canonical live value).
	ShowcaseYawDeg = 25,
	-- View-axis lift to near eye level. CURRENT: 0.12.
	ShowcaseElevation = 0.12,
	-- Look-target lift as a fraction of bbox height (face focus
	-- while still enclosing full bounds). CURRENT: 0.10.
	TargetLiftFrac = 0.10,
	-- Near-plane headroom as a fraction of bbox radius, with an
	-- absolute floor so small animals frame close-up.
	-- CURRENT: 0.08 / 0.12.
	HeadroomFrac = 0.08,
	HeadroomMin = 0.12,
	-- Floor against degenerate/empty bounds. CURRENT: 0.3 studs.
	MinDistance = 0.3,
}

-- --- Rarity gradient shading -----------------------------------------------------

Sell.RarityGradient = {
	-- Lerp toward white for the first stop. CURRENT: 0.45.
	LightenT = 0.45,
	-- Scale toward black for the last stop. CURRENT: 0.55.
	DarkenT = 0.55,
}

-- --- Flow --------------------------------------------------------------------------------

-- Preview result timeout: a pending preview that never resolves
-- cleans itself up after this. Safety net, not gameplay.
-- Type: number. Unit: seconds. CURRENT: 8.
Sell.ResultTimeout = 8

-- --- Labels (player-facing; see Messages catalogs for toasts) -------------------------------

Sell.Labels = {
	-- 'Sell for $<Format(raw)>'.
	SellForPrefix = 'Sell for $',
	-- Shown when the animal has no mutations.
	NoMutations = 'None',
	-- Level fallbacks when data is missing.
	LevelUnknown = 'Lv. ?',
	LevelNotApplicable = 'N/A',
	-- Rarity title fallback.
	RarityUnknown = '?',
}

function Sell.Validate(): { string }
	local issues: { string } = {}
	local function num(path: string, v: any, min: number)
		if type(v) ~= 'number' or v ~= v or v < min then
			issues[#issues + 1] = path .. ' must be a number >= ' .. tostring(min)
		end
	end
	num('Viewport.PreviewScale', Sell.Viewport.PreviewScale, 0.001)
	num('Viewport.ShowcaseMargin', Sell.Viewport.ShowcaseMargin, 1)
	num('Viewport.ShowcaseZoom', Sell.Viewport.ShowcaseZoom, 0.001)
	num('Viewport.MinDistance', Sell.Viewport.MinDistance, 0)
	num('RarityGradient.LightenT', Sell.RarityGradient.LightenT, 0)
	num('RarityGradient.DarkenT', Sell.RarityGradient.DarkenT, 0)
	num('ResultTimeout', Sell.ResultTimeout, 0.001)
	if typeof(Sell.Viewport.OriginPosition) ~= 'Vector3' then
		issues[#issues + 1] = 'Viewport.OriginPosition must be a Vector3'
	end
	return issues
end

return table.freeze(Sell)
