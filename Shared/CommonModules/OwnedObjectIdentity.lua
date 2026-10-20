--!strict
--!native
--[[
	OwnedObjectIdentity
	===================
	Centralized identity for every owned object the server
	persists: Animals and Eggs.

	Phase 2.2: identity used to be minted inline wherever a record
	was created (AnimalService.CreateFromEgg,
	AnimalService.SpawnFromPersistence,
	Egg/SpawnService._spawnCenter, _spawnPersistence). Every
	call site re-derived the format, so a format change meant touching
	four places, and the rejoin path minted a fresh id instead of
	reading the one the player already owned.

	This module is the single source of truth for:
	  - what an id looks like (per-kind namespace)
	  - how to mint one (server-generated, non-empty, stable)
	  - how to recognize a valid one
	  - how to mint one that doesn't collide with a given set
	    (bounded retry, hard failure)

	Ids are opaque strings. Nothing outside this module knows the
	token format; if the format changes, this file is the only one
	the changes.

 	Kind namespace. An Animal and an Egg live in separate
 	namespaces (AN_ vs EG_ for new ids; BR_ vs LB_ for legacy
 	ids migrated on load) so a registry keyed by id can never
 	confuse the two. `KindOf` recovers the canonical kind from
 	an id for logging and for the repair path.

	Server authority. `Generate` takes no input — the client never
	supplies an id, so a client can never manufacture ownership.
	Repair (the reconcile path in PlayerService) can mint a fresh
	id for a record that lost its own, but only on the server, and
	only when the record is genuinely ownerless.
]]

local OwnedObjectIdentity = {}

-- Kinds. `Animal`/`Egg` are canonical: all newly minted ids
-- use AN_/EG_. `Brainrot`/`LuckyBlock` are legacy aliases kept
-- so existing BR_/LB_ ids keep resolving (load-time migration
-- rewrites them; direct callers with old kinds still work).
local Kind = {
	Brainrot = 'Brainrot',
	LuckyBlock = 'LuckyBlock',
	Animal = 'Animal',
	Egg = 'Egg',
}

export type Kind = 'Brainrot' | 'LuckyBlock' | 'Animal' | 'Egg'

-- Per-kind prefix. Canonical namespaces are AN_ (animals) and
-- EG_ (eggs). BR_/LB_ are legacy namespaces, recognized forever
-- by KindOf/MigrateLegacyId but never minted for new objects.
local PREFIX = {
	[Kind.Brainrot] = 'BR_',
	[Kind.LuckyBlock] = 'LB_',
	[Kind.Animal] = 'AN_',
	[Kind.Egg] = 'EG_',
}

-- Token alphabet. Base-62 keeps ids short (10 chars ~= 60 bits
-- of entropy) without needing a counter that itself has to be
-- persisted.
local ALPHABET = '0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ'

local TOKEN_LENGTH = 10

-- Bounded retry ceiling. After this many attempts the generator
-- gives up and throws rather than silently creating duplicate
-- state (spec §9).
local MAX_COLLISION_RETRIES = 8

-- --- Internal helpers -------------------------------------------

local function randomToken(length: number): string
	local out = {}
	for _ = 1, length do
		local idx = math.random(1, #ALPHABET)
		out[#out + 1] = string.sub(ALPHABET, idx, idx)
	end
	return table.concat(out)
end

-- --- Public API -------------------------------------------------

-- Mint a fresh id. The token is server-generated; the client
-- never supplies it, so a client can't manufacture ownership.
function OwnedObjectIdentity.Generate(kind: string): string
	assert(Kind[kind] ~= nil, 'invalid identity kind: ' .. tostring(kind))
	return PREFIX[kind] .. randomToken(TOKEN_LENGTH)
end

-- Recognize a valid id. Rejects nil, non-strings, empty strings,
-- wrong prefix, and malformed tokens. Ids are opaque, so the only
-- structural requirement is the kind prefix plus a non-empty
-- alphanumeric body.
function OwnedObjectIdentity.IsValid(id: any, kind: string): boolean
	if Kind[kind] == nil then
		return false
	end
	if type(id) ~= 'string' then
		return false
	end
	local prefix = PREFIX[kind]
	if #id <= #prefix or string.sub(id, 1, #prefix) ~= prefix then
		return false
	end
	local body = string.sub(id, #prefix + 1)
	for i = 1, #body do
		local c = string.sub(body, i, i)
		if string.find(ALPHABET, c, 1, true) == nil then
			return false
		end
	end
	return true
end

-- Mint an id that is not already in `existing`. `existing` is a
-- set-like table (any truthy value), so a runtime registry keyed
-- by id passes in directly. Bounded retry: after
-- MAX_COLLISION_RETRIES attempts the generator throws with a
-- useful server-side error instead of silently producing a
-- duplicate (spec §9).
--
-- `existing` may be nil (no known ids yet) — the first mint never
-- needs a collision check.
function OwnedObjectIdentity.GenerateUnique(kind: string, existing: { [string]: any }?): string
	if existing == nil or not next(existing) then
		return OwnedObjectIdentity.Generate(kind)
	end
	for _ = 1, MAX_COLLISION_RETRIES do
		local candidate = OwnedObjectIdentity.Generate(kind)
		if existing[candidate] == nil then
			return candidate
		end
	end
	error(
		string.format(
			'OwnedObjectIdentity: failed to mint a unique %s id after %d attempts',
			kind,
			MAX_COLLISION_RETRIES
		)
	)
end

-- Extract the CANONICAL kind from an id, or nil if the id is
-- not a recognizable owned-object id. Legacy BR_/LB_ prefixes
-- resolve to 'Animal'/'Egg' (same as AN_/EG_) — useful for
-- logging and for the repair path, which needs to know what
-- it's looking at regardless of id vintage.
function OwnedObjectIdentity.KindOf(id: any): string?
	if type(id) ~= 'string' then
		return nil
	end
	for kind, prefix in pairs(PREFIX) do
		if string.sub(id, 1, #prefix) == prefix then
			if kind == Kind.Brainrot then
				return Kind.Animal
			elseif kind == Kind.LuckyBlock then
				return Kind.Egg
			end
			return kind
		end
	end
	return nil
end

-- Rewrite a legacy BR_/LB_ id to its canonical AN_/EG_ form,
-- preserving the token body. Returns the migrated id, or nil
-- when the input is not a migratable legacy id of
-- `canonicalKind` (which must be Kind.Animal or Kind.Egg).
-- Already-canonical ids are NOT passed through (use IsValid
-- for that check) — nil means "cannot migrate", never
-- "already fine". Bodies are re-validated against the token
-- alphabet so a malformed legacy id can never launder itself
-- into the canonical namespace.
function OwnedObjectIdentity.MigrateLegacyId(id: any, canonicalKind: string): string?
	if canonicalKind ~= Kind.Animal and canonicalKind ~= Kind.Egg then
		return nil
	end
	if type(id) ~= 'string' then
		return nil
	end
	local legacyKind = if canonicalKind == Kind.Animal then Kind.Brainrot else Kind.LuckyBlock
	local legacyPrefix = PREFIX[legacyKind]
	if #id <= #legacyPrefix or string.sub(id, 1, #legacyPrefix) ~= legacyPrefix then
		return nil
	end
	local body = string.sub(id, #legacyPrefix + 1)
	if #body == 0 then
		return nil
	end
	for i = 1, #body do
		local c = string.sub(body, i, i)
		if string.find(ALPHABET, c, 1, true) == nil then
			return nil
		end
	end
	return PREFIX[canonicalKind] .. body
end

OwnedObjectIdentity.Kind = Kind

return table.freeze(OwnedObjectIdentity)
