--!strict
--!native
--[[
	RebirthUnlocks
	==============
	Pure derivation of "what does this Rebirth unlock" for PRESENTATION.
	The gameplay itself needs no derivation: stand counts flow through
	RebirthConfig.StandsFor (consumed by DynamicSlotService) and gear
	access flows through GearConfig.RequiredRebirth (consumed by
	GearShopService.GetPlayerRebirth + GearConfig.IsLocked). This module
	only answers, from those SAME two authoritative configs, what the
	Rebirth UI's UnlockItems section should display — never the reverse.

	Unlock entries (all amounts are DELTAS, never absolute counts):
	  { Kind = 'AnimalStand', Amount = n }  (+n normal stands)
	  { Kind = 'ArenaStand', Amount = n }   (+n arena stands)
	  { Kind = 'Gear', GearId = id, Amount = 1 }  (gear newly gated by
	    this Rebirth: every GearConfig entry whose RequiredRebirth
	    equals the completed Rebirth number, in catalog order)

	Stand deltas are next-counts minus current-counts floored at 0, so
	a Rebirth that keeps a count flat produces NO card for it (never
	"5 Animal Stands" when the reward is actually "+0"). Gear unlocks
	fall out of the existing RequiredRebirth ladder — no second
	unlock schema, no parallel config.

	Pure (configs only, no Instances, no yields): safe to require from
	server (BuildState) and headless specs alike.
]]

local RebirthConfig = require(script.Parent.Parent.Config.Economy.Rebirth)
local GearConfig = require(script.Parent.Parent.Config.Economy.Gear)
local OverheadConfig = require(script.Parent.Parent.Config.Presentation.UI).Overhead

local RebirthUnlocks = {}

RebirthUnlocks.Kind = table.freeze({
	AnimalStand = 'AnimalStand',
	ArenaStand = 'ArenaStand',
	Gear = 'Gear',
})

-- Presentation colors (presentation only — never gameplay). Both
-- reuse existing canonical constants, never new values:
--   White = OverheadConfig.FallbackColor (the canonical white).
--   ArenaGold = OverheadConfig.TraitColors.Gold (the one Color3
--     literally named Gold, live on Gold-trait overheads).
RebirthUnlocks.White = OverheadConfig.FallbackColor
RebirthUnlocks.ArenaGold = OverheadConfig.TraitColors.Gold

export type UnlockEntry = {
	Kind: string,
	Amount: number,
	GearId: string?,
}

-- Human-readable card title source of truth. Both stand kinds
-- display plain "Stand" (the card visual + gold/white Name color
-- tells them apart); gear titles come from the canonical
-- GearConfig display Name (never the internal Id).
function RebirthUnlocks.DisplayName(entry: UnlockEntry): string
	if type(entry) ~= 'table' then
		return '?'
	end
	if entry.Kind == RebirthUnlocks.Kind.Gear then
		if type(entry.GearId) == 'string' then
			local found: any = nil
			pcall(function()
				found = GearConfig.FindGear(entry.GearId)
			end)
			if type(found) == 'table' and type(found.Name) == 'string' then
				return found.Name
			end
			return entry.GearId
		end
		return '?'
	end
	if entry.Kind == RebirthUnlocks.Kind.AnimalStand or entry.Kind == RebirthUnlocks.Kind.ArenaStand then
		return 'Stand'
	end
	return '?'
end

-- Name text color source of truth. Everything is white except the
-- Arena Stand name, which gets the canonical gold. The 8D outline
-- is ALWAYS white regardless (see StandShowcase) — only the Name
-- text may be gold, never the model or the outline.
function RebirthUnlocks.NameColor(entry: UnlockEntry): Color3
	if type(entry) == 'table' and entry.Kind == RebirthUnlocks.Kind.ArenaStand then
		return RebirthUnlocks.ArenaGold
	end
	return RebirthUnlocks.White
end

-- Number field visibility source of truth. Stand deltas show their
-- +N count; gear cards hide Number entirely (a tool unlock is
-- conceptually one item — no count is shown).
function RebirthUnlocks.NumberVisible(entry: UnlockEntry): boolean
	if type(entry) == 'table' and entry.Kind == RebirthUnlocks.Kind.Gear then
		return false
	end
	return true
end

-- "+N" card count. Single source for the UnlockItems Number field so
-- server snapshots and client fallbacks can never disagree.
function RebirthUnlocks.CountText(amount: any): string
	local n = tonumber(amount) or 0
	if n ~= math.floor(n) or n < 0 then
		n = 0
	end
	return '+' .. tostring(n)
end

-- Unlocks granted BY completing `nextIndex` (the previewed Rebirth),
-- given the player's `currentRebirth`. Empty (never nil) when the
-- entry is missing, maxed, or nothing changes. Only positive stand
-- deltas and matching gears are emitted, in stable order: Animal
-- stands, Arena stands, then gears in GearConfig catalog order.
function RebirthUnlocks.BuildForPreview(currentRebirth: number, nextIndex: number): { UnlockEntry }
	local out: { UnlockEntry } = {}
	if type(currentRebirth) ~= 'number' or type(nextIndex) ~= 'number' then
		return out
	end
	if currentRebirth ~= math.floor(currentRebirth) or nextIndex ~= math.floor(nextIndex) then
		return out
	end
	if nextIndex < 1 or nextIndex ~= currentRebirth + 1 then
		return out
	end
	local entry: any = nil
	pcall(function()
		entry = RebirthConfig.Get(nextIndex)
	end)
	if type(entry) ~= 'table' or type(entry.Stands) ~= 'table' then
		return out
	end
	local current: { Animal: number, Arena: number } = { Animal = 0, Arena = 0 }
	pcall(function()
		current = RebirthConfig.StandsFor(currentRebirth)
	end)
	local function delta(want: any, have: any): number
		local w = tonumber(want) or 0
		local h = tonumber(have) or 0
		local d = math.floor(w) - math.floor(h)
		if d < 0 then
			d = 0
		end
		return d
	end
	local animalDelta = delta(entry.Stands.Animal, current.Animal)
	if animalDelta > 0 then
		out[#out + 1] = { Kind = RebirthUnlocks.Kind.AnimalStand, Amount = animalDelta }
	end
	local arenaDelta = delta(entry.Stands.Arena, current.Arena)
	if arenaDelta > 0 then
		out[#out + 1] = { Kind = RebirthUnlocks.Kind.ArenaStand, Amount = arenaDelta }
	end
	-- Gear unlocks: the existing RequiredRebirth ladder IS the unlock
	-- definition (same field GearShopService gates purchases on).
	local gears: { any }? = nil
	pcall(function()
		gears = GearConfig.GetAll()
	end)
	if type(gears) == 'table' then
		for _, gear in ipairs(gears) do
			if type(gear) == 'table' and gear.RequiredRebirth == nextIndex then
				out[#out + 1] = {
					Kind = RebirthUnlocks.Kind.Gear,
					Amount = 1,
					GearId = gear.Id,
				}
			end
		end
	end
	return out
end

-- Change signature for the client's rebuild gate (stable order in,
-- stable string out). Includes the previewed index so switching the
-- previewed Rebirth always rebuilds even when contents coincide.
function RebirthUnlocks.Signature(nextIndex: number, unlocks: { UnlockEntry }): string
	if type(unlocks) ~= 'table' then
		return tostring(nextIndex) .. ':none'
	end
	local parts: { string } = {}
	for _, entry in ipairs(unlocks) do
		if type(entry) == 'table' then
			parts[#parts + 1] = ('%s|%s|%s'):format(
				tostring(entry.Kind),
				tostring(entry.GearId),
				tostring(entry.Amount)
			)
		end
	end
	return tostring(nextIndex) .. ':' .. table.concat(parts, ';')
end

return table.freeze(RebirthUnlocks)
