--!strict
--!native
--[[
	AdminArgs
	=========
	Server-side canonical argument resolution for admin commands.
	Every resolver revalidates against the live canonical config /
	service, independent of whatever client autocomplete suggested.
	Client autocomplete is UX only; THESE functions are the gate.

	Data-model rules enforced here (mirroring the authoritative
	systems, never redefined):
	  * Trait: EXACTLY zero or one (nil = none). Multi-trait
	    input is rejected loudly, never silently truncated.
	  * Mutations: N UNIQUE valid ids (possibly zero).
	    Duplicates and unknown ids are rejected loudly.
	  * Animal defIds resolve through AnimalConfig.Get.
	  * Egg rarities resolve through EggConfig.Price.
	  * Gear resolves through GearConfig.FindGear.
	  * Codes resolve through CodesConfig.FindById.

	Conventions: each resolver returns (ok, value | errorString).
	Callers surface the error string to the admin verbatim.
]]

local ReplicatedStorage = game:GetService('ReplicatedStorage')

local AnimalConfig = require(ReplicatedStorage.Config.Creatures.Animals)
local EggConfig = require(ReplicatedStorage.Config.Creatures.Eggs)
local TraitConfig = require(ReplicatedStorage.Config.Creatures.Traits)
local MutationConfig = require(ReplicatedStorage.Config.Creatures.Mutations)
local GearConfig = require(ReplicatedStorage.Config.Economy.Gear)
local CodesConfig = require(ReplicatedStorage.Config.Economy.Rewards).Codes
local RarityConfig = require(ReplicatedStorage.Config.Creatures.Rarity)
local LevelConfig = require(ReplicatedStorage.Config.Creatures.Progression)
local RebirthConfig = require(ReplicatedStorage.Config.Economy.Rebirth)
local ArenaConfig = require(ReplicatedStorage.Config.World.Arena)

local AdminArgs = {}

-- Canonical animal definition id (case-insensitive) or error.
-- Returns (true, defId, rarity, def).
function AdminArgs.ResolveAnimal(raw: any): (boolean, any, any, any)
	if type(raw) ~= 'string' then
		return false, 'Animal must be a definition id (e.g. "Dragon").'
	end
	local rarity, def = AnimalConfig.Get(raw)
	if rarity ~= nil and def ~= nil then
		return true, raw, rarity, def
	end
	for bucketRarity, bucket in pairs(AnimalConfig.Catalog) do
		for defId, entry in pairs(bucket) do
			if string.lower(defId) == string.lower(raw) then
				return true, defId, bucketRarity, entry
			end
		end
	end
	-- Display-name fallback (case-insensitive).
	for bucketRarity, bucket in pairs(AnimalConfig.Catalog) do
		for defId, entry in pairs(bucket) do
			if type(entry.displayName) == 'string' and string.lower(entry.displayName) == string.lower(raw) then
				return true, defId, bucketRarity, entry
			end
		end
	end
	return false, ('Unknown animal "%s".'):format(tostring(raw))
end

-- Canonical egg rarity (case-insensitive) or error.
function AdminArgs.ResolveRarity(raw: any): (boolean, any)
	if type(raw) ~= 'string' then
		return false, 'Egg rarity must be text (e.g. "Legendary").'
	end
	if EggConfig.Price[raw] ~= nil then
		return true, raw
	end
	for _, rarity in ipairs(RarityConfig.Order) do
		if string.lower(rarity) == string.lower(raw) then
			return true, rarity
		end
	end
	return false, ('Unknown egg rarity "%s".'):format(tostring(raw))
end

-- Canonical single trait or nil (none-markers) or error.
-- Multi-value input (commas) is rejected: animals carry at most
-- ONE trait and silently taking the first would corrupt intent.
function AdminArgs.ResolveTrait(raw: any): (boolean, any)
	if raw == nil then
		return true, nil
	end
	if type(raw) ~= 'string' then
		return false, 'Trait must be a single trait id (e.g. "Gold") or "-" for none.'
	end
	local text = (string.gsub(string.gsub(raw, '^%s+', ''), '%s+$', ''))
	if text == '' or text == '-' or string.lower(text) == 'none' then
		return true, nil
	end
	if string.find(text, ',') ~= nil then
		return false, 'Animals support only one trait; pass a single trait, not a list.'
	end
	if TraitConfig.Get(text) ~= nil then
		return true, text
	end
	for id in pairs(TraitConfig.Catalog) do
		if string.lower(id) == string.lower(text) then
			return true, id
		end
	end
	return false, ('Invalid trait: "%s"'):format(text)
end

-- Canonical unique mutation list (possibly empty) or error.
-- Accepts an already-parsed array (from the mutationList Cmdr
-- type) or raw comma/space-separated text. Duplicates and
-- unknown ids fail loudly; nothing is silently dropped.
function AdminArgs.ResolveMutations(raw: any): (boolean, any)
	if raw == nil then
		return true, {}
	end
	local ids: { string } = {}
	if type(raw) == 'table' then
		for _, id in ipairs(raw) do
			if type(id) ~= 'string' then
				return false, 'Invalid mutation: entry must be text.'
			end
			ids[#ids + 1] = id
		end
	elseif type(raw) == 'string' then
		local text = (string.gsub(raw, '[%[%]%"]', ''))
		text = (string.gsub(text, '^%s+', ''))
		text = (string.gsub(text, '%s+$', ''))
		if text == '' or text == '-' or string.lower(text) == 'none' then
			return true, {}
		end
		for token in string.gmatch(text, '[^,%s]+') do
			ids[#ids + 1] = token
		end
	else
		return false, 'Mutations must be a comma-separated list (e.g. "Galactic,Frost") or "-" for none.'
	end
	-- Case-insensitive canonicalization BEFORE uniqueness, so
	-- "frost,Frost" is correctly reported as a duplicate.
	local seen: { [string]: boolean } = {}
	local out: { string } = {}
	for _, id in ipairs(ids) do
		local canonical: string? = nil
		if MutationConfig.Get(id) ~= nil then
			canonical = id
		else
			for known in pairs(MutationConfig.Catalog) do
				if string.lower(known) == string.lower(id) then
					canonical = known
					break
				end
			end
		end
		if canonical == nil then
			return false, ('Invalid mutation: "%s"'):format(tostring(id))
		end
		if seen[canonical] then
			return false, ('Duplicate mutation: "%s"'):format(canonical)
		end
		seen[canonical] = true
		out[#out + 1] = canonical
	end
	table.sort(out)
	return true, out
end

-- Canonical gear Id or error (accepts Id or display Name).
function AdminArgs.ResolveGear(raw: any): (boolean, any, any)
	if type(raw) ~= 'string' then
		return false, 'Gear must be a gear id or name (e.g. "SilverBat").'
	end
	local found = GearConfig.FindGear(raw)
	if found ~= nil then
		return true, found.Id, found
	end
	for _, entry in ipairs(GearConfig.GetAll()) do
		if string.lower(entry.Id) == string.lower(raw) or string.lower(entry.Name) == string.lower(raw) then
			return true, entry.Id, entry
		end
	end
	return false, ('Unknown gear "%s".'):format(tostring(raw))
end

-- Canonical code Id or error (normalizes like the redeem path).
function AdminArgs.ResolveCode(raw: any): (boolean, any, any)
	local norm = CodesConfig.NormalizeCode(raw)
	if norm == nil then
		return false, 'Code must be non-empty text.'
	end
	local def = CodesConfig.FindById(norm)
	if def == nil then
		return false, ('Unknown code "%s".'):format(norm)
	end
	return true, norm, def
end

-- Animal level within the authoritative ceiling or error.
function AdminArgs.ResolveAnimalLevel(raw: any): (boolean, any)
	if type(raw) ~= 'number' or raw ~= math.floor(raw) then
		return false, 'Level must be a whole number.'
	end
	if raw < 1 or raw > LevelConfig.MaxLevel then
		return false, ('Level must be between 1 and %d.'):format(LevelConfig.MaxLevel)
	end
	return true, raw
end

-- Arena stage within the authoritative ceiling or error.
function AdminArgs.ResolveArenaLevel(raw: any): (boolean, any)
	if type(raw) ~= 'number' or raw ~= math.floor(raw) then
		return false, 'Arena level must be a whole number.'
	end
	local maxLevel = 50
	pcall(function()
		maxLevel = ArenaConfig.MaxLevel()
	end)
	if raw < 1 or raw > maxLevel then
		return false, ('Arena level must be between 1 and %d.'):format(maxLevel)
	end
	return true, raw
end

-- Rebirth index within the authored sequence or error.
function AdminArgs.ResolveRebirthIndex(raw: any): (boolean, any)
	if type(raw) ~= 'number' or raw ~= math.floor(raw) then
		return false, 'Rebirth must be a whole number.'
	end
	local maxConfigured = 3
	pcall(function()
		maxConfigured = RebirthConfig.MaxConfigured()
	end)
	if raw < 0 or raw > maxConfigured then
		return false, ('Rebirth must be between 0 and %d.'):format(maxConfigured)
	end
	return true, raw
end

-- Quantity within a caller-supplied bound or error.
function AdminArgs.ResolveQuantity(raw: any, maxQty: number): (boolean, any)
	local qty = 1
	if raw ~= nil then
		if type(raw) ~= 'number' or raw ~= math.floor(raw) then
			return false, 'Quantity must be a whole number.'
		end
		qty = raw
	end
	if qty < 1 or qty > maxQty then
		return false, ('Quantity must be between 1 and %d.'):format(maxQty)
	end
	return true, qty
end

return table.freeze(AdminArgs)
