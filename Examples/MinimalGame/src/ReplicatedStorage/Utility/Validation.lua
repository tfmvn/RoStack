--!strict
--[[
	Validation
	==========
	Re-export of `osyrisrblx/t` plus the canonical schemas used by
	every service's public API and every remote entry point.

	If a public function is missing a schema here, that's a bug —
	it means a new public surface was added without exposing its
	shape for reuse and verification.
]]

local t = require(script.Parent.Parent.Packages.t)
local Rarity = require(script.Parent.Parent.Types.RarityType)
local BigNumber = require(script.Parent.BigNumber)
local StudioTestMode = require(script.Parent.StudioTestMode)

local Validation = {}

Validation.t = t
Validation.check = t.check
Validation.strict = t.strict

-- A positive integer in safe range. Used for userId, cash, etc.
local function isPositiveInteger(value: any): boolean
	if typeof(value) ~= 'number' then
		return false
	end
	if value ~= value then
		return false
	end
	if math.floor(value) ~= value then
		return false
	end
	return value >= 1 and value <= 1_000_000_000
end
Validation.PositiveInteger = isPositiveInteger

-- A 0..1 float. Used for normalised chance values.
local function isUnitFloat(value: any): boolean
	if typeof(value) ~= 'number' then
		return false
	end
	return value >= 0 and value <= 1
end
Validation.UnitFloat = isUnitFloat

-- A 1..99 integer (used for slot indices).
local function isSlotIndex(value: any): boolean
	if typeof(value) ~= 'number' then
		return false
	end
	if math.floor(value) ~= value then
		return false
	end
	return value >= 1 and value <= 99
end
Validation.SlotIndex = isSlotIndex

-- A ROBLOX PLAYER UserId. This is the ONE centralized Player
-- UserId gate — every ownership/permission check on a Player
-- UserId (bases, carry, steal, profiles, slots, animals, eggs)
-- must use this instead of inline `userId <= 0` comparisons.
--
-- Live behavior: positive integers only. Anything else is
-- INVALID, exactly as before.
--
-- Studio dev-only: Roblox Studio multi-instance test players
-- get UserIds 0, -1, -2, ... Positive Studio ids already pass
-- the normal path; 0 and negatives are additionally accepted —
-- but ONLY when StudioTestMode.IsEnabled() holds, i.e. BOTH:
--   1. RunService:IsStudio() == true (never a live server), AND
--   2. the dev opted in (DebugConfig.AllowStudioTestUserIds at
--      boot, or StudioTestMode.Enabled from the command bar).
-- A published server therefore rejects 0/negatives even if a
-- flag was accidentally left on. Fractions, NaN, infinities
-- and non-numbers are ALWAYS invalid, flag or not.
--
-- This is ONLY for Player.UserId. Other numeric ids (slot
-- indices, levels, XP, amounts, prices) keep their own
-- schemas (PositiveInteger/SlotIndex/BaseIndex) and are
-- unaffected by dev mode.
local function isValidPlayerUserId(value: any): boolean
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
	if value >= 1 then
		return true
	end
	-- 0 and negatives: Studio multi-instance test players only.
	return StudioTestMode.IsEnabled() and StudioTestMode.IsTestUserId(value)
end
Validation.IsValidPlayerUserId = isValidPlayerUserId

-- A 1..9999 integer (used for base index, prices).
local function isBaseIndex(value: any): boolean
	if typeof(value) ~= 'number' then
		return false
	end
	if math.floor(value) ~= value then
		return false
	end
	return value >= 1 and value <= 9999
end
Validation.BaseIndex = isBaseIndex

-- A roblox Instance whose ClassName is exactly the given string.
function Validation.instanceOf(className: string)
	return t.instanceOf(className)
end

-- A player: must be a Player, must still be in-game.
-- If a Player has a non-nil Parent, it is necessarily a descendant
-- of Players (the only place Players exist), so a Parent check is
-- sufficient and avoids a per-call GetService.
local function isLivePlayer(value: any): boolean
	return typeof(value) == 'Instance' and value:IsA('Player') and value.Parent ~= nil
end
Validation.LivePlayer = isLivePlayer

-- A live CHARACTER Model: present in the world with a living
-- Humanoid. Pure on the Model (no Player needed), so unit
-- tests can build throwaway characters. A dead/dying
-- character (Health <= 0), a removed model (Parent nil), or a
-- rig without a Humanoid is NOT live. Used for the
-- death/reset interaction lockout: endpoints that move,
-- transfer, or attach gameplay objects must reject non-live
-- characters even when the Player instance itself is live
-- (death keeps the Player parented while the Humanoid is at
-- 0 and through the respawn transition).
local function isLiveCharacter(character: any): boolean
	if typeof(character) ~= 'Instance' or not (character :: Instance):IsA('Model') then
		return false
	end
	if (character :: Model).Parent == nil then
		return false
	end
	local humanoid = (character :: Model):FindFirstChildOfClass('Humanoid')
	if not humanoid then
		return false
	end
	local ok, health = pcall(function()
		return (humanoid :: Humanoid).Health
	end)
	if not ok or type(health) ~= 'number' or health ~= health or health <= 0 then
		return false
	end
	return true
end
Validation.IsLiveCharacter = isLiveCharacter

-- Server-authoritative interaction authority: may this player
-- initiate gameplay interactions (steal, grab, place, hatch,
-- collect) RIGHT NOW? False for dead/dying/resetting/
-- respawning players: the Player instance survives death
-- (still parented), so LivePlayer alone is NOT sufficient —
-- the CURRENT character must be live too. Read live on every
-- call (no caching): death and respawn change the answer
-- within the same second. Every mutating player-initiated
-- endpoint gates on this; internal server recovery paths
-- (which act FOR the player, not AS them) do not.
--
-- Trust boundary note: non-Player shims (plain tables used by
-- unit tests and a few server-internal call paths) pass
-- through — their own LivePlayer/domain gates still apply
-- downstream. This is airtight in production: every network
-- boundary (ProximityPrompt.Triggered, RemoteEvent handlers)
-- supplies engine Player instances, which are fully gated
-- here; a client can never smuggle a table past the engine.
local function canPlayerInteract(player: any): boolean
	if typeof(player) ~= 'Instance' or not (player :: Instance):IsA('Player') then
		return true
	end
	if not isLivePlayer(player) then
		return false
	end
	return isLiveCharacter((player :: Player).Character)
end
Validation.CanPlayerInteract = canPlayerInteract

-- A non-empty string with max length 64.
local function isShortString(value: any): boolean
	if typeof(value) ~= 'string' then
		return false
	end
	local len = #value
	return len >= 1 and len <= 64
end
Validation.ShortString = isShortString

-- Slot id: p7:<userId>:<kind>:<index>. The userId segment
-- accepts an optional minus sign so Studio multi-instance
-- test players (UserIds 0, -1, -2, ...) keep working slot ids
-- (p7:-1:slot:3). This is structural only: such ids can never
-- exist outside Studio dev mode (SlotType.BuildId refuses to
-- mint them there), and every ownership decision still goes
-- through IsValidPlayerUserId.
local function slotIdPattern(value: any): boolean
	if typeof(value) ~= 'string' then
		return false
	end
	return string.match(value, '^p7:-?%d+:[a-z]+:%d+$') ~= nil
end
Validation.SlotId = slotIdPattern

-- A rarity string. Rarity enum is small; allow any of the 8.
local function isRarity(value: any): boolean
	return value == Rarity.Common
		or value == Rarity.Uncommon
		or value == Rarity.Rare
		or value == Rarity.Epic
		or value == Rarity.Mythic
		or value == Rarity.Legendary
		or value == Rarity.Divine
		or value == Rarity.Secret
end
Validation.Rarity = isRarity

-- A non-empty table. Used for opaque "table" payloads.
Validation.AnyTable = t.table

-- A canonical BigNumber string: a non-empty sequence of
-- decimal digits with an optional single decimal point.
-- Delegates to `BigNumber.isValid` so the predicate and the
-- runtime use the SAME definition of "valid". A malformed
-- amount from a Cmdr command (e.g. "abc", "1.2.3", "-5",
-- "1e10", "Infinity", "NaN", "") fails the predicate
-- instead of crashing the server.
local function isBigNumberString(value: any): boolean
	return BigNumber.isValid(value)
end
Validation.BigNumberString = isBigNumberString

return table.freeze(Validation)
