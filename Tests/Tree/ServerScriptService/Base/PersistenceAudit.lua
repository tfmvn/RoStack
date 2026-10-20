--!strict
--!native
--[[
	PersistenceAudit
	================
	Phase 2.5.1 — the ONE validation layer for the persisted
	inventory (profile.Data.Brainrots / profile.Data.LuckyBlocks).
	Runs on every profile load, BEFORE any runtime reconstruction
	(BaseService.RestorePlayerBase), so the load path can never
	see an invalid or ambiguous record without it being detected,
	repaired, or quarantined — loudly.

	WHY THIS EXISTS (the Phase 2.5.1 root cause): pre-2.2 call
	sites passed SlotIds into the Id-keyed Remove* persistence
	APIs. Every such call was a silent no-op, so consumed /
	refunded / re-slotted Eggs left stale records in
	profile.Data.LuckyBlocks. After an Animal was created on the
	same slot, the profile claimed BOTH an LB and a BR for one
	SlotId, and the LB-first restore order made the phantom win —
	the player's Animal "turned into" an Egg after a
	rejoin. This module makes that state impossible to load
	quietly.

	POLICY (Phase 2.5.1 spec §7/§8/§17/§19/§23):
	  * TYPE IS NEVER CONVERTED. A record in the Animals list is
	    an Animal, in the Eggs list an Egg — by the
	    explicit `Type` stamp every record now carries (and by list
	    membership). A malformed record is repaired in place or
	    quarantined; it is never reinterpreted as the other kind,
	    and it never migrates between the two lists.
	  * Animal WINS a cross-kind slot collision. When an Animal
	    and an Egg claim the same SlotId, the Egg
	    record is the phantom (the egg was consumed by the open
	    flow that created the Animal), so it is quarantined.
	    Deterministic — the loader never "picks one".
	  * Same-kind duplicates (Id or SlotId): first occurrence
	    wins, later duplicates are quarantined.
	  * REPAIR, not drop, wherever the object can still be
	    reconstructed: missing/wrong-namespace Id -> fresh mint in
	    the list's namespace (identity changes, the object does
	    not); malformed Level/XP -> LevelConfig.Normalize;
	    missing/wrong `Type` stamp -> re-stamped.
	  * QUARANTINE (removed from the profile with a loud issue)
	    only when the record cannot be reconstructed at all: a
	    non-table row, a duplicate, or a cross-kind collision
	    loser.
	  * UNKNOWN DefId / unknown Rarity are REPORTED here but left
	    for the existing spawn-path drop policy
	    (AnimalService._dropPersistedAndNotify), which notifies
	    the owner — the audit does not duplicate that decision.
	  * A record with a missing/invalid SlotId is KEPT and
	    reported; RestorePlayerBase re-homes it to a free slot
	    where possible (preserve as much valid data as possible).
	  * Trait/Mutations (Phase 2.11): MISSING fields are normal
	    pre-2.11 saves — Animal.Trait nil, both Mutations lists
	    {} (silent, not repairs). Present-but-invalid trait ids
	    clear to nil; invalid/duplicate mutation ids drop — both
	    with loud issues. Nothing is ever quarantined for these
	    optional fields alone.
	  * CashPool (Phase 2.6): a MISSING field is a normal pre-2.6
	    save — stamp '0' silently (not a repair). A NUMBER value
	    recovers through tostring + BigNumber.sanitize (counted
	    as a repair). A present-but-invalid value is reset to '0'
	    with a loud issue: the pool is lost, the Animal is not.
	    Egg records never carry a pool and are untouched.

	`Audit` returns FRESH LISTS the caller assigns back onto
	profile.Data (the input lists themselves are never reordered
	or truncated); individual record tables are repaired in place
	and are shared references with the input — the caller owns
	assigning the cleaned lists back. No yields, no Workspace
	access, no service calls — safe to run mid-load.
]]

local ReplicatedStorage = game:GetService('ReplicatedStorage')

local LevelConfig = require(ReplicatedStorage.Config.Creatures.Progression)
local TraitConfig = require(ReplicatedStorage.Config.Creatures.Traits)
local MutationConfig = require(ReplicatedStorage.Config.Creatures.Mutations)
local AnimalConfig = require(ReplicatedStorage.Config.Creatures.Animals)
local EggConfig = require(ReplicatedStorage.Config.Creatures.Eggs)
local BigNumber = require(ReplicatedStorage.Utility.BigNumber)
local OwnedObjectIdentity = require(ReplicatedStorage.Utility.OwnedObjectIdentity)
local Validation = require(ReplicatedStorage.Utility.Validation)

local PersistenceAudit = {}

export type AuditResult = {
	Animals: { any },
	Eggs: { any },
	Issues: { string },
	Quarantined: number,
	Repaired: number,
}

-- --- Per-kind record cleaning -----------------------------------

-- Clean one Egg record. Returns (cleanRecord, issue?)
-- where cleanRecord is nil when the record must be quarantined.
local function _cleanEgg(record: any, seenIds: { [string]: boolean }, issues: { string }, repaired: { number }): any?
	if type(record) ~= 'table' then
		issues[#issues + 1] = 'Eggs: non-table record quarantined'
		return nil
	end

	-- Type stamp: the explicit discriminator (Phase 2.5.1 §4).
	-- List membership decides the type; a missing or wrong stamp
	-- is repaired to match it.
	if record.Type ~= 'LuckyBlock' then
		issues[#issues + 1] = ('Eggs: %s had Type=%s, re-stamped to Egg'):format(
			tostring(record.Id),
			tostring(record.Type)
		)
		repaired[1] += 1
	end

	-- Identity. An Egg record must carry a valid EG_ id.
	-- Load-time migration (2.11.5): a legacy LB_ id is rewritten
	-- to EG_ with the same token body (counts as repaired, not
	-- quarantined). A wrong-namespace id (AN_...) is a filing
	-- error, not a type change: mint a fresh EG_ id and keep the
	-- object.
	if not OwnedObjectIdentity.IsValid(record.Id, OwnedObjectIdentity.Kind.Egg) then
		local migrated = OwnedObjectIdentity.MigrateLegacyId(record.Id, OwnedObjectIdentity.Kind.Egg)
		if migrated then
			issues[#issues + 1] = ('Eggs: legacy id %s migrated to %s'):format(tostring(record.Id), migrated)
			repaired[1] += 1
			record.Id = migrated
		else
			local fresh = OwnedObjectIdentity.GenerateUnique(OwnedObjectIdentity.Kind.Egg, seenIds)
			issues[#issues + 1] = ('Eggs: record had invalid id %s; minted %s (object preserved)'):format(
				tostring(record.Id),
				fresh
			)
			repaired[1] += 1
			record.Id = fresh
		end
	end
	if seenIds[record.Id] then
		issues[#issues + 1] = ('Eggs: duplicate Id %s — later record quarantined'):format(tostring(record.Id))
		return nil
	end

	-- Rarity must be a purchasable tier. Reported, not dropped —
	-- the spawn path owns that failure (with owner notification).
	if type(record.Rarity) ~= 'string' or not EggConfig.Price[record.Rarity] then
		issues[#issues + 1] = ('Eggs: %s has unknown rarity %s (spawn path will drop it)'):format(
			tostring(record.Id),
			tostring(record.Rarity)
		)
	end

	-- SlotId: structurally validated only (the base is assigned
	-- after the audit, so ids cannot be resolved to parts yet).
	-- Kept + reported; RestorePlayerBase re-homes it.
	if type(record.SlotId) ~= 'string' or not Validation.SlotId(record.SlotId) then
		issues[#issues + 1] = ('Eggs: %s has invalid SlotId %s (restore will re-home)'):format(
			tostring(record.Id),
			tostring(record.SlotId)
		)
	end

	-- Mutations (Phase 2.11): missing -> {} (normal pre-2.11
	-- save, silent); validated + deduped through the one
	-- canonical path, invalid ids dropped with a loud issue.
	if record.Mutations == nil then
		record.Mutations = {}
	else
		local clean = MutationConfig.SanitizeIds(record.Mutations)
		if #clean ~= (type(record.Mutations) == 'table' and #record.Mutations or -1) then
			issues[#issues + 1] = ('Eggs: %s had invalid/duplicate Mutations; cleaned'):format(tostring(record.Id))
			repaired[1] += 1
		end
		record.Mutations = clean
	end
	-- Pending Trait (Phase 2.11): nil is the normal case (rolled
	-- at open). Present-but-unknown -> nil with a loud issue;
	-- the egg itself is never dropped for it.
	if record.Trait ~= nil then
		if type(record.Trait) ~= 'string' or TraitConfig.Get(record.Trait) == nil then
			issues[#issues + 1] = ('Eggs: %s had invalid pending Trait %s; cleared'):format(
				tostring(record.Id),
				tostring(record.Trait)
			)
			repaired[1] += 1
			record.Trait = nil
		end
	end

	record.Type = 'LuckyBlock'
	seenIds[record.Id] = true
	return record
end

-- Clean one Animal record. Same contract as _cleanEgg.
local function _cleanAnimal(record: any, seenIds: { [string]: boolean }, issues: { string }, repaired: { number }): any?
	if type(record) ~= 'table' then
		issues[#issues + 1] = 'Animals: non-table record quarantined'
		return nil
	end

	if record.Type ~= 'Brainrot' then
		issues[#issues + 1] = ('Animals: %s had Type=%s, re-stamped to Animal'):format(
			tostring(record.Id),
			tostring(record.Type)
		)
		repaired[1] += 1
	end

	-- Identity: an Animal record must carry a valid AN_ id. A
	-- wrong-namespace id is re-keyed — the record's TYPE (list
	-- membership + stamp) is authoritative, never the id prefix.
	-- Load-time migration (2.11.5): legacy BR_ ids rewrite to AN_
	-- with the same token body (repaired, not quarantined).
	if not OwnedObjectIdentity.IsValid(record.Id, OwnedObjectIdentity.Kind.Animal) then
		local migrated = OwnedObjectIdentity.MigrateLegacyId(record.Id, OwnedObjectIdentity.Kind.Animal)
		if migrated then
			issues[#issues + 1] = ('Animals: legacy id %s migrated to %s'):format(tostring(record.Id), migrated)
			repaired[1] += 1
			record.Id = migrated
		else
			local fresh = OwnedObjectIdentity.GenerateUnique(OwnedObjectIdentity.Kind.Animal, seenIds)
			issues[#issues + 1] = ('Animals: record had invalid id %s; minted %s (object preserved)'):format(
				tostring(record.Id),
				fresh
			)
			repaired[1] += 1
			record.Id = fresh
		end
	end
	if seenIds[record.Id] then
		issues[#issues + 1] = ('Animals: duplicate Id %s — later record quarantined'):format(tostring(record.Id))
		return nil
	end

	-- DefId existence: reported here, dropped by the spawn path
	-- (which notifies the owner). The audit never converts the
	-- record on this basis (§17).
	if type(record.DefId) ~= 'string' or not AnimalConfig.Get(record.DefId) then
		issues[#issues + 1] = ('Animals: %s has unknown DefId %s (spawn path will drop it)'):format(
			tostring(record.Id),
			tostring(record.DefId)
		)
	end

	-- SlotId: structural only, kept + reported (restore re-homes).
	if type(record.SlotId) ~= 'string' or not Validation.SlotId(record.SlotId) then
		issues[#issues + 1] = ('Animals: %s has invalid SlotId %s (restore will re-home)'):format(
			tostring(record.Id),
			tostring(record.SlotId)
		)
	end

	-- Level/XP: canonical repair through LevelConfig.Normalize —
	-- the one normalization system (Phase 2.4/2.5 contract).
	local level, xp = LevelConfig.Normalize(record.Level, record.XP)
	if level ~= record.Level or xp ~= record.XP then
		repaired[1] += 1
	end
	record.Level = level
	record.XP = xp

	-- CashPool: BigNumber string (Phase 2.6). Policy in the
	-- module header — silent '0' stamp when missing, recover a
	-- number, loud reset when unrecoverable.
	if record.CashPool == nil then
		record.CashPool = '0'
	else
		local raw = if type(record.CashPool) == 'number' then tostring(record.CashPool) else record.CashPool
		local pool = BigNumber.sanitize(raw)
		if pool then
			if pool ~= record.CashPool then
				repaired[1] += 1
			end
			record.CashPool = pool
		else
			issues[#issues + 1] = ('Animals: %s had invalid CashPool %s; reset to 0'):format(
				tostring(record.Id),
				tostring(record.CashPool)
			)
			record.CashPool = '0'
		end
	end

	-- Trait (Phase 2.11): nil is valid (no trait). Present but
	-- unknown -> nil with a loud issue; the animal is never
	-- dropped for it.
	if record.Trait ~= nil then
		if type(record.Trait) ~= 'string' or TraitConfig.Get(record.Trait) == nil then
			issues[#issues + 1] = ('Animals: %s had invalid Trait %s; cleared'):format(
				tostring(record.Id),
				tostring(record.Trait)
			)
			repaired[1] += 1
			record.Trait = nil
		end
	end
	-- Mutations (Phase 2.11): missing -> {} (normal pre-2.11
	-- save, silent); validated + deduped, invalid dropped loud.
	if record.Mutations == nil then
		record.Mutations = {}
	else
		local clean = MutationConfig.SanitizeIds(record.Mutations)
		if #clean ~= (type(record.Mutations) == 'table' and #record.Mutations or -1) then
			issues[#issues + 1] = ('Animals: %s had invalid/duplicate Mutations; cleaned'):format(tostring(record.Id))
			repaired[1] += 1
		end
		record.Mutations = clean
	end

	record.Type = 'Brainrot'
	seenIds[record.Id] = true
	return record
end

-- --- Public API ---------------------------------------------------

-- Audit (and clean) the persisted inventory. See the module
-- header for the policy. Never throws on malformed input; every
-- anomaly lands in `.Issues` as a human-readable line.
function PersistenceAudit.Audit(profileData: any): AuditResult
	local issues: { string } = {}
	local repaired = { 0 }
	local quarantined = 0

	local rawAnimals = type(profileData) == 'table' and profileData.Brainrots or nil
	local rawEggs = type(profileData) == 'table' and profileData.LuckyBlocks or nil
	if type(rawAnimals) ~= 'table' then
		rawAnimals = {}
	end
	if type(rawEggs) ~= 'table' then
		rawEggs = {}
	end

	-- Pass 1: per-list structural validation + repair.
	local seenAnimalIds: { [string]: boolean } = {}
	local animals: { any } = {}
	for _, record in ipairs(rawAnimals) do
		local cleaned = _cleanAnimal(record, seenAnimalIds, issues, repaired)
		if cleaned then
			animals[#animals + 1] = cleaned
		else
			quarantined += 1
		end
	end

	local seenEggIds: { [string]: boolean } = {}
	local eggs: { any } = {}
	for _, record in ipairs(rawEggs) do
		local cleaned = _cleanEgg(record, seenEggIds, issues, repaired)
		if cleaned then
			eggs[#eggs + 1] = cleaned
		else
			quarantined += 1
		end
	end

	-- Pass 2: same-kind duplicate SlotIds. First record wins;
	-- later records are quarantined (they would otherwise make
	-- the restore order decide — the nondeterminism §8 forbids).
	local animalSlots: { [string]: boolean } = {}
	local keptAnimals: { any } = {}
	for _, record in ipairs(animals) do
		local slotKey = type(record.SlotId) == 'string' and record.SlotId or tostring(record.SlotId)
		if animalSlots[slotKey] then
			issues[#issues + 1] = ('Animals: duplicate SlotId %s (Id %s) — later record quarantined'):format(
				tostring(record.SlotId),
				tostring(record.Id)
			)
			quarantined += 1
			continue
		end
		animalSlots[slotKey] = true
		keptAnimals[#keptAnimals + 1] = record
	end

	local eggSlots: { [string]: boolean } = {}
	local keptEggs: { any } = {}
	for _, record in ipairs(eggs) do
		local slotKey = type(record.SlotId) == 'string' and record.SlotId or tostring(record.SlotId)
		if eggSlots[slotKey] then
			issues[#issues + 1] = ('Eggs: duplicate SlotId %s (Id %s) — later record quarantined'):format(
				tostring(record.SlotId),
				tostring(record.Id)
			)
			quarantined += 1
			continue
		end
		eggSlots[slotKey] = true
		keptEggs[#keptEggs + 1] = record
	end

	-- Pass 3: cross-kind slot collision. An Animal and an Egg
	-- claiming the same SlotId means a phantom Egg
	-- record survived its own open (the Phase 2.5.1 root cause).
	-- The Animal wins; the LB record is quarantined. This is
	-- deterministic and never reinterprets either record's type.
	for _, animal in ipairs(keptAnimals) do
		local slotKey = type(animal.SlotId) == 'string' and animal.SlotId or nil
		if slotKey and eggSlots[slotKey] then
			issues[#issues + 1] = (
				'Slot %s claimed by BOTH an Animal and an Egg — phantom Egg record quarantined '
				.. '(animal Id %s preserved)'
			):format(slotKey, tostring(animal.Id))
			eggSlots[slotKey] = nil
			quarantined += 1
		end
	end
	local finalEggs: { any } = {}
	for _, record in ipairs(keptEggs) do
		local slotKey = type(record.SlotId) == 'string' and record.SlotId or nil
		-- Keep records that still hold their slot (won the
		-- collision) or never had a valid one (restore re-homes
		-- them). Collision losers were quarantined in the loop
		-- above.
		if slotKey == nil or eggSlots[slotKey] then
			finalEggs[#finalEggs + 1] = record
		end
	end

	return {
		Brainrots = keptAnimals,
		LuckyBlocks = finalEggs,
		Issues = issues,
		Quarantined = quarantined,
		Repaired = repaired[1],
	}
end

return table.freeze(PersistenceAudit)
