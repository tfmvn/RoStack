--!strict
--[[
	SlotType
	========
	A slot is a sub-position inside a Base. With the unified-pool
	refactor (Phase 2), every base has exactly SlotCount slots that
	can hold either an Egg or an Animal (or be empty).
	Spec Phase 2 §3.

	Slot ids are stable strings of the form:
	  p7:<userId>:slot:<index>

	The id's third segment is the literal token `slot`. The
	runtime occupant discriminator lives on `slot.occupantKind`
	(`'egg' | 'animal' | nil`), not in the id. This is the
	single source of truth for "what kind of thing is on this slot".

	The userId prefix is intentional: it keeps ids globally unique
	across players and avoids accidental cross-player reference.

 	Why we keep the third segment at all: the persistence layer
 	stores `{SlotId, DefId|Rarity}` keyed by slot id, and the
 	parser has a permissive regex that accepts any `[a-z]+`
 	token. Keeping a stable keyword (vs dropping the segment
 	entirely) means the parser shape is unchanged and persisted
 	records keep their 3-segment id structure (only the keyword
 	shifts from `lucky`/`animal` to `slot`).

 	Studio dev-only: the userId segment accepts Studio
 	multi-instance test ids (0, -1, -2, ...) as `p7:-1:slot:3`.
 	BuildId mints them only in Studio dev mode; ParseId parses
 	them structurally anywhere (callers still validate via
 	Validation.IsValidPlayerUserId, which rejects them live).
 ]]

local StudioTestMode = require(script.Parent.Parent.Utility.StudioTestMode)

-- Id segment keyword. Always 'slot' for new ids.
local SlotKind = {
	Slot = 'slot',
}

export type SlotKind = 'slot'

-- Runtime occupant discriminator. Stored on the slot record as
-- `slot.occupantKind`. This is what callers should branch on
-- (not the id).
local OccupantKind = {
	Egg = 'egg',
	Animal = 'animal',
}

export type OccupantKind = 'egg' | 'animal'

local SlotState = {
	Empty = 'Empty', -- not in use
	Reserved = 'Reserved', -- a logic operation has claimed it (race guard)
	Occupied = 'Occupied', -- a real object (egg / animal) is in it
}

export type SlotState = 'Empty' | 'Reserved' | 'Occupied'

-- Arena slot index namespace (single source of truth): arena
-- stand <k> uses index ArenaSlotIndexBase + k, so arena
-- SlotIds (`p7:<userId>:slot:<index>`) can never collide with
-- normal slots (1..99) while staying inside the canonical id
-- format every validator, persistence key, and slot index
-- parses. Scope itself lives on the record (`slot.arena`),
-- never in the id.
local ArenaSlotIndexBase = 1000
local MaxArenaStands = 99

export type Slot = {
	id: string,
	ownerUserId: number,
	baseId: string,
	-- Id-segment keyword; always SlotKind.Slot. Kept on the record
	-- for symmetry with prior type; not used as a discriminator.
	kind: SlotKind,
	index: number,
	state: SlotState,
	occupantId: string?, -- Egg.uniqueId or Animal.uniqueId
	-- Runtime discriminator. nil when state != Occupied. Set by
	-- OccupySlot(slotId, occupantId, occupantKind).
	occupantKind: OccupantKind?,
	_mutex: boolean,
	-- Visual reference (server-side). Set by the service that owns
	-- the physical part; not used in any cross-service wire payload.
	part: BasePart?,
	-- Index into Bases.Slots.Offsets for layout.
	offset: Vector3,
}

-- Back-compat alias so older call sites that import `Kind` keep
-- working. New code should use `SlotKind.Slot` or `OccupantKind.*`
-- as appropriate.
local function BuildId(userId: number, _kind: SlotKind?, index: number): string
	-- Production: non-negative integer ids only. Studio
	-- dev-only: StudioTestMode test ids (0, -1, ...) may be
	-- minted when dev mode is enabled (IsStudio + opt-in);
	-- live servers always take the first branch.
	assert(
		(type(userId) == 'number' and userId >= 0)
			or (StudioTestMode.IsEnabled() and StudioTestMode.IsTestUserId(userId)),
		'invalid userId'
	)
	-- _kind is ignored: the unified pool always uses the `slot` keyword.
	-- The parameter is kept for back-compat with prior call sites that
	-- passed `SlotKind.LuckyBlock` or `SlotKind.Brainrot` — those values
	-- are no longer meaningful, and we silently coerce to `slot`.
	local function isValidIndex(idx: number): boolean
		if type(idx) ~= 'number' or idx ~= math.floor(idx) or idx < 1 then
			return false
		end
		if idx <= 99 then
			return true
		end
		return idx >= ArenaSlotIndexBase and idx <= ArenaSlotIndexBase + MaxArenaStands
	end
	assert(isValidIndex(index), 'slot index out of range')
	return string.format('p7:%d:%s:%d', userId, SlotKind.Slot, index)
end

-- Parsed result table. Returns nil on failure.
--
-- `kind` is the id-segment keyword, always `'slot'` for new ids.
-- Callers that need the occupant kind should read `slot.occupantKind`
-- from the resolved record, NOT the id.
export type ParsedSlotId = { userId: number, kind: SlotKind, index: number }

local function ParseId(id: string): ParsedSlotId?
	-- Strict pattern first; then a permissive [a-z]+ matcher. The
	-- permissive fallback lets us parse legacy ids (`lucky`,
	-- `animal`) and any future keyword without code changes.
	-- The userId segment allows an optional minus sign so
	-- Studio test ids (p7:-1:slot:3) parse structurally;
	-- ownership VALIDATION still happens at callers via
	-- Validation.IsValidPlayerUserId (live rejects them).
	local userId, kind, index = string.match(id, '^p7:(-?%d+):([a-z]+):(%d+)$')
	if not userId then
		return nil
	end
	-- Normalize legacy kinds to the unified token. New code is
	-- expected to emit only `slot`, but old records (and any in-
	-- flight data) are tolerated here without error.
	if kind ~= SlotKind.Slot then
		kind = SlotKind.Slot
	end
	return {
		userId = tonumber(userId) :: number,
		kind = kind :: SlotKind,
		index = tonumber(index) :: number,
	}
end

return {
	Kind = table.freeze(SlotKind),
	OccupantKind = table.freeze(OccupantKind),
	State = table.freeze(SlotState),
	BuildId = BuildId,
	ParseId = ParseId,
	ArenaSlotIndexBase = ArenaSlotIndexBase,
	MaxArenaStands = MaxArenaStands,
}
