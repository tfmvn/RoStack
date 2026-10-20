--!strict
--[[
	StudioTestMode
	==============
	Development-only runtime switch for Roblox Studio
	multi-instance testing. Studio test players receive
	UserIds like 0, -1, -2, ... which production validation
	correctly rejects — this module lets Studio test sessions
	opt into accepting them WITHOUT weakening live behavior.

	Why a separate mutable module (and not just the DebugConfig
	flag): DebugConfig is table.freeze()d, so neither the Studio
	command bar nor specs can flip a flag that lives on it at
	runtime. DebugConfig.AllowStudioTestUserIds remains the
	DECLARED default; bootstrap copies it here once at
	boot, and developers flip THIS module afterwards:

	  Studio command bar:
	    require(game.ReplicatedStorage.Utility.StudioTestMode).Enabled = true

	Leaf module by design: requires ONLY RunService, so even
	low-level Types modules (SlotType) can require it without
	creating a require cycle.

	Safety (hard requirements, all enforced in IsEnabled /
	IsTestUserId — never trust the flag alone):
	  * Enabled defaults to false.
	  * IsEnabled() is true ONLY when Enabled == true AND
	    RunService:IsStudio() == true. A published server
	    returns false even if the flag was somehow left on.
	  * IsTestUserId() accepts ONLY integers in [-100, 0]
	    (the observed Studio multi-instance range). Positive
	    ids use the normal production path; arbitrary
	    negatives, fractions, NaN, infinities and non-numbers
	    are never test ids.
]]

local RunService = game:GetService('RunService')

local StudioTestMode = {
	-- Flip to true from the Studio command bar (or bootstrap
	-- sync) to enable Studio test UserIds for this session.
	-- Never frozen on purpose. Production default: false.
	Enabled = false,
}

-- Upper bound of the Studio test-id range. Studio
-- multi-instance sessions hand out 0, -1, -2, ...; -100 is
-- orders of magnitude above any real test session
-- (ServerMaxPlayers = 5) while keeping the bypass narrow.
local TEST_USER_ID_MIN = -100

-- True only in a Studio session that opted in. Published
-- servers ALWAYS return false, flag or not.
function StudioTestMode.IsEnabled(): boolean
	if StudioTestMode.Enabled ~= true then
		return false
	end
	local ok, isStudio = pcall(function()
		return RunService:IsStudio()
	end)
	return ok and isStudio == true
end

-- True for the Studio multi-instance test-id shape: integer
-- UserIds in [TEST_USER_ID_MIN, 0]. Positive ids are real
-- production ids (handled by the normal path, not here).
function StudioTestMode.IsTestUserId(value: any): boolean
	if typeof(value) ~= 'number' then
		return false
	end
	if value ~= value then
		return false
	end
	if value == math.huge or value == -math.huge then
		return false
	end
	if math.floor(value) ~= value then
		return false
	end
	return value <= 0 and value >= TEST_USER_ID_MIN
end

-- Deliberately NOT table.freeze()d: the whole point is flipping
-- Enabled at runtime from the Studio command bar / specs.
return StudioTestMode
