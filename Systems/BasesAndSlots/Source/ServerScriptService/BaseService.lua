--!strict
--!native
--[[
	BaseService
	===========
	Owns:
	  * The 6-base registry and per-base unified slot pool
	  * Per-base / per-slot mutex for race protection
	  * Slot reservation / occupation / demotion / release primitives
	  * Wire-level slot snapshots for PlayerState pushes
	  * Rejoin restoration: re-occupies persisted slots and asks
	    the lucky egg / animal services to re-spawn their
	    runtime instances
	  * Collector-facing rotation: at RegisterBases time, every
	    slot's Yaw is set to point at the base's `Collector`
	    part (lookAt semantics — slot's +Z points AT the
	    Collector). The Collector is a REQUIRED Studio asset:
	    a base without one is a fatal startup error, not a
	    fallback (see `_resolveCollector` for why). The
	    resolved part and facing are stashed on
	    `base.collector` / `base.collectorFacing` so
	    downstream services can read them without re-walking
	    the Workspace tree.

	Does NOT own:
	  * Player data (PlayerService)
	  * Egg visual models (EggService)
	  * Animal visual models (AnimalService)

	Spec §9-§17, §28 (Phase 1); Phase 2 §3-§13.

	Phase 2 (unified-slot) changes:
	  * Single `slots[1..SlotCount]` pool per base; no separate
	    Egg / Animal sub-pools.
	  * New `DemoteSlotToReserved` primitive for the grab path
	    (Occupied → Reserved so the slot is held for the
	    player's return).
	  * `ReserveSlot` is now idempotent on already-Reserved
	    (no-op success) so place-to-original can skip the
	    re-reserve.
	  * `OccupySlot` takes an optional `occupantKind` so the
	    service can stamp the slot's runtime kind.
	  * `GetFreeSlot` and `ReleaseReservedSlotForUser` drop
	    the `kind` parameter (single pool).
	  * `Snapshot` returns `{ slots[1..SlotCount], _occupiedCount }`
	    in place of the prior two-list shape.

	Phase 3 (SlotService split) changes:
	  * Slot primitives (GetFreeSlot, ReserveSlot,
	    DemoteSlotToReserved, OccupySlot, ReleaseSlot,
	    FindSlotByOccupant, ReleaseReservedSlotForUser,
	    _findSlotById) live in `Base/SlotService.lua`.
	    BaseService keeps thin pass-throughs that call into
	    SlotService and log a deprecation warning.
	  * `BaseService.SetSlotService(svc)` wires the callback
	    hooks: BaseService passes SlotService a callback that
	    updates the base's `_occupiedCount` on Occupy/Release.
	  * `BaseService.RegisterBases` calls
	    `SlotService.RegisterBase(base)` after building the
	    slot table. `ReleaseBase` / `CleanupPlayer` call
	    `SlotService.UnregisterBase(baseId)`.
	    `AssignBaseForPlayer` / `AssignBaseById` call
	    `SlotService.SetBaseOwner` + `RebaseSlotIds`.
	  * `BaseService.Snapshot` builds the slot array via
	    `SlotService.SnapshotBaseSlots`.
	  * `GetNearestValidSlotForPlayer` is **deprecated**;
	    Phase 4 removes it when the Place prompt moves to
	    slot parts.
]]

local Bases = require(script.Parent.Parent.ReplicatedStorage.Config.World.Bases)
local BaseConfig = require(script.Parent.Parent.ReplicatedStorage.Config.World.Bases)
local BaseType = require(script.Parent.Parent.ReplicatedStorage.Types.BaseType)
local SlotType = require(script.Parent.Parent.ReplicatedStorage.Types.SlotType)
local Validation = require(script.Parent.Parent.ReplicatedStorage.Utility.Validation)
local Debug = require(script.Parent.Parent.ReplicatedStorage.Utility.Debug)
local StandResolver = require(script.Parent.Parent.ReplicatedStorage.Utility.StandResolver)
local PlayerBoard = require(script.Parent.Base.PlayerBoard)
local DynamicSlotService = require(script.Parent.Base.DynamicSlotService)

local Players = game:GetService('Players')

local BaseService = {}

-- --- Internal helpers --------------------------------------------

-- The asset recipe repeated in both Collector errors. Kept in
-- one place so the two messages cannot drift apart.
local COLLECTOR_RECIPE = "Create: Part named 'Collector', Anchored = true, CanCollide = false, "
	.. 'CanTouch = true, Size = (6, 1, 6), CFrame = Spawn.CFrame + (0, 0, -10). '
	.. 'See Docs/StudioAssets/base-collector.md and '
	.. 'Docs/decisions/ADR-004-slot-service-split.md §D4.'

-- Resolve a base's `Collector` part and the yaw-only CFrame
-- that, when applied to a slot, makes the slot's +Z (front
-- surface) point AT that Collector.
--
-- ERRORS rather than falling back. The Collector is not
-- decoration: it is the cash target AND the reference that
-- orients every slot in the base, so a missing one would
-- silently mis-rotate all `SlotCount` slots and leave lucky
-- egg flights with nowhere to land. `RegisterBases`
-- auto-creates `Spawn` when absent because its position is
-- derivable from config (the legacy `Slots` / `Slot<n>`
-- dev-defaults are only built when `AnimalStands` is absent
-- entirely); the
-- Collector's placement encodes base ORIENTATION, which is a
-- design decision the server cannot guess. Failing at startup
-- with the exact path is strictly better than booting into a
-- place where every base is subtly wrong.
--
-- Why look-at, not copy-rotation: placed items should face the
-- Collector's POSITION (a flat slot "looking at" a target),
-- not inherit the Collector's own orientation.
--
-- The math: we want the slot's +Z to point from baseCenter
-- to collector.Position. Roblox's Part `FrontFace` is the
-- +Z surface, so a slot's "front" is its +Z. For a yaw-only
-- CFrame `CFrame.Angles(0, yaw, 0)`, the +Z axis in world
-- coords is `(sin(yaw), 0, cos(yaw))`. Setting that equal to
-- the unit direction from baseCenter to the Collector:
--   sin(yaw) = toCollector.X / |toCollector|
--   cos(yaw) = toCollector.Z / |toCollector|
-- which gives `yaw = atan2(toCollector.X, toCollector.Z)`.
local function _resolveCollector(baseFolder: Instance, baseCenter: Vector3): (BasePart, CFrame)
	-- The path is derived from the live folder, so it stays
	-- correct for the authoritative `Workspace.Map.Bases`
	-- container (and any fallback): never hard-code the
	-- container prefix here.
	local path = baseFolder:GetFullName() .. '.Collector'
	-- The documented contract is a direct `Collector` BasePart
	-- child, used as-is. Tolerated: a `Collector` Model (a
	-- decorated Studio build) — resolves to its PrimaryPart,
	-- else its first descendant BasePart. Anything else is the
	-- historical fatal error below. The server NEVER creates a
	-- Collector: its placement encodes base orientation, which
	-- cannot be guessed.
	local node = baseFolder:FindFirstChild('Collector')
	local collector: BasePart? = nil
	if node ~= nil then
		if node:IsA('BasePart') then
			collector = node
		elseif node:IsA('Model') then
			local model = node :: Model
			local primary = model.PrimaryPart
			if primary and primary:IsA('BasePart') then
				collector = primary
			else
				for _, descendant in ipairs(model:GetDescendants()) do
					if descendant:IsA('BasePart') then
						collector = descendant
						break
					end
				end
			end
		end
	end
	if not collector then
		if node == nil then
			error(
				'BaseService.RegisterBases: '
					.. path
					.. ' is missing. Every base requires a Collector '
					.. 'BasePart — it is the cash target AND the reference that orients every slot, so the '
					.. 'server will not guess one. '
					.. COLLECTOR_RECIPE,
				0
			)
		end
		error(
			'BaseService.RegisterBases: '
				.. path
				.. ' is a '
				.. (node :: Instance).ClassName
				.. ', not a BasePart (or a Model containing one). The Collector must resolve to a part so its Position can orient the slots '
				.. 'and its surface can be touched. '
				.. COLLECTOR_RECIPE,
			0
		)
	end
	local resolved = collector :: BasePart
	Debug.Log('BS', 'Collector resolved', { path = path, part = resolved:GetFullName() })
	local toCollector = resolved.Position - baseCenter
	if math.abs(toCollector.X) < 0.001 and math.abs(toCollector.Z) < 0.001 then
		-- The Collector exists but sits directly above/below the
		-- base center, so there is no XZ direction to derive a
		-- Yaw from. A different failure from "missing": the fix
		-- is to MOVE it, not to create one.
		error(
			'BaseService.RegisterBases: '
				.. path
				.. ' shares the XZ position of the base Spawn, so no slot facing can be derived from it. '
				.. 'Move the Collector off the Spawn axis — the conventional placement is '
				.. 'Spawn.CFrame + (0, 0, -10).',
			0
		)
	end
	local yaw = math.atan2(toCollector.X, toCollector.Z)
	return resolved, CFrame.Angles(0, yaw, 0)
end

-- Ensure a slot carries its per-slot `CashCollector` trigger
-- volume (Phase 2.6, legacy `Slots` fallback path only — MAIN
-- GAME stands use their Studio-authored `Button.PressPart`
-- as-is and never auto-create triggers). The canonical asset
-- is a BasePart named CashCollector parented to the slot part;
-- a Studio-authored one is used AS-IS (position, size, look —
-- no overrides). When it is absent (today's default place), a
-- dev-default one is created: a thin vertical Neon volume
-- standing on the slot's collector-facing edge (+Z).
-- CanCollide stays false — it is a touch trigger, not a wall —
-- and it spans the slot width and ~4 studs of height so a
-- player walking up to the slot front touches it with any body
-- part. This is the same ensure-pattern RegisterBases already
-- uses for Spawn / Slots / Slot<n> (geometry derivable from
-- config); a Studio-authored part always wins.
local function _ensureCashCollector(slotPart: BasePart): BasePart
	local existing = slotPart:FindFirstChild('CashCollector')
	if existing then
		if existing:IsA('BasePart') then
			return existing
		end
		Debug.Warn('BS', 'Slot has a CashCollector child that is not a BasePart; creating a dev-default one', {
			slot = slotPart:GetFullName(),
			className = existing.ClassName,
		})
	end
	local height = BaseConfig.Collector.Height
	local part = Instance.new('Part')
	part.Name = 'CashCollector'
	part.Size = Vector3.new(Bases.Slots.Size.X, height, 0.4)
	part.Anchored = true
	part.CanCollide = false
	part.Material = Enum.Material.Neon
	part.Color = BaseConfig.Collector.PartColor
	part.Transparency = BaseConfig.Collector.Transparency
	-- Local +Z is the collector-facing edge (see _resolveCollector):
	-- stand on the slot surface at that edge, nudged inward so the
	-- volume overlaps the slot's front edge and a touch registers
	-- even when the slot sits flush with the base floor.
	part.CFrame = slotPart.CFrame
		* CFrame.new(0, Bases.Slots.Size.Y / 2 + height / 2, Bases.Slots.Size.Z / 2 - 0.1)
	part.Parent = slotPart
	return part
end

-- --- Internal state ----------------------------------------------

local bases: { [string]: any } = {} -- baseId -> Base record
local basesByOwner: { [number]: string } = {} -- userId -> baseId

local playerServiceRef: any = nil
local eggServiceRef: any = nil
local animalServiceRef: any = nil
local slotServiceRef: any = nil
-- MAIN GAME: BaseLockService owns runtime lock state. Wired by
-- bootstrap via SetBaseLockService (one-directional: this module
-- never requires it, so there is no cycle). All calls are
-- nil-safe so the service works when locking is unwired (tests).
local baseLockServiceRef: any = nil

-- --- API ----------------------------------------------------------

function BaseService.Init() end

function BaseService.SetPlayerService(svc: any)
	playerServiceRef = svc
end

function BaseService.SetEggService(svc: any)
	eggServiceRef = svc
end

function BaseService.SetAnimalService(svc: any)
	animalServiceRef = svc
end

-- MAIN GAME: inject the BaseLockService so ownership transitions
-- reset lock state. Called once by bootstrap after both modules
-- are loaded. Missing/unwired service = no-op (never an error).
function BaseService.SetBaseLockService(svc: any)
	baseLockServiceRef = svc
end

-- Wires the SlotService reference and the occupied-count
-- callback. Must be called before `RegisterBases`.
function BaseService.SetSlotService(svc: any)
	slotServiceRef = svc
	if svc then
		-- Single source of truth for occupied-count
		-- update on slot transitions. SlotService
		-- invokes this with `(slot, delta)` after
		-- OccupySlot (+1) and ReleaseSlot (-1).
		-- The callback is stored in a local upvalue
		-- inside SlotService so it can be replaced
		-- even though the module table is frozen.
		svc.SetOccupiedCountCallback(function(slot: any, delta: number)
			-- Arena occupancy is team membership, NOT base
			-- capacity: arena transitions must never move the
			-- normal occupied count (or flip base state).
			if type(slot) == 'table' and slot.arena == true then
				return
			end
			local base = bases[slot.baseId]
			if not base then
				return
			end
			if delta > 0 then
				base._occupiedCount = base._occupiedCount + 1
				if base.state == BaseType.State.Reserved then
					base.state = BaseType.State.Occupied
				end
			elseif delta < 0 then
				base._occupiedCount = math.max(0, base._occupiedCount - 1)
			end
		end)
	end
end

-- --- Registration -------------------------------------------------

-- Scans the authoritative base container (`Workspace.Map.Bases`,
-- resolved via StandResolver.GetBasesFolder) for `Base_<i>`
-- folders. Each base folder must contain:
--   * Spawn (Part) — used to compute spawn CFrame
--   * Collector (BasePart) — REQUIRED, fatal when missing
--   * AnimalStands (Folder) — MAIN GAME stand hierarchy, child
--     `Stand<n>` parts (see StandResolver for the exact shape)
-- If the human-built tree is missing, this method creates the
-- non-stand scaffolding.
--
-- Stand discovery (MAIN GAME): when `Base.AnimalStands` exists,
-- one slot record is registered per `Stand<n>` (sorted
-- numerically), with `slot.part = Stand.Slot.Root` and
-- `slot.cashCollector = Stand.Button.PressPart`. The
-- `Stand<n>` <-> slot-index mapping is the persistence
-- compatibility layer: internal slot ids
-- (`p7:<userId>:slot:<index>`) are NEVER renamed because
-- Studio calls the object a stand. Studio stand transforms are
-- NEVER overwritten here — position and rotation stay exactly
-- as authored. Missing stand pieces resolve to nil (display /
-- trigger degrade with a warn); nothing is auto-created under
-- AnimalStands.
--
-- Legacy fallback: when `AnimalStands` is absent (bare
-- workspaces in tests / dev), the prior unified `Slots` folder
-- + `Slot<n>` behavior is preserved verbatim so existing
-- harnesses keep working.
--
-- Phase 2: a single unified slot pool replaces the prior
-- per-kind slot-folder pair. Legacy folders in an already-built
-- Studio file are left alone (the code never reads them) and
-- can be deleted by the developer at their leisure.
function BaseService.RegisterBases(workspace: Instance)
	Debug.Log('BS', '> RegisterBases', { baseCount = tostring(Bases.Count) })
	Validation.t.instanceOf('Workspace')(workspace)
	-- MAIN GAME: the authoritative container is
	-- `Workspace.Map.Bases`. The legacy top-level
	-- `Workspace.Bases` resolves only on bare test/dev
	-- workspaces. If neither exists, fail loudly naming the
	-- authoritative path — NEVER create `Workspace.Bases`
	-- (auto-creating it is what produced the empty
	-- `Workspace.Bases.Base_1` with `children={}` and the
	-- bogus "Collector is missing" error).
	local basesFolder = StandResolver.GetBasesFolder(workspace)
	if not basesFolder then
		error(
			'BaseService.RegisterBases: Workspace.Map.Bases is missing. Bases live under Workspace.Map.Bases '
				.. '(Base_1..Base_'
				.. tostring(Bases.Count)
				.. ', each with Collector, Spawn, PlayerBoard, AnimalStands). '
				.. 'The server will not use or create a top-level Workspace.Bases container.',
			0
		)
	end

	for i = 1, Bases.Count do
		local id = BaseType.BuildId(i)
		local baseFolder = basesFolder:FindFirstChild(id)
		if not baseFolder then
			baseFolder = Instance.new('Folder')
			baseFolder.Name = id
			baseFolder.Parent = basesFolder
		end

		-- One-time boot diagnostics (collector investigation).
		-- Proves exactly what the server sees for this base
		-- BEFORE any fatal validation, so a "Collector is
		-- missing" error can be matched against the real
		-- folder contents (wrong folder? typo'd name?
		-- wrong class? missing on a different base than the
		-- one inspected?). Runs once per base at startup via
		-- print (always on); never per-frame, never scanned
		-- beyond the base's direct children.
		do
			local childNames: { string } = {}
			for _, child in ipairs(baseFolder:GetChildren()) do
				childNames[#childNames + 1] = child.Name .. ' [' .. child.ClassName .. ']'
			end
			table.sort(childNames)
						Debug.Log('BaseService', ('Base=%s folder=%s class=%s children={%s}'):format(
					id,
					baseFolder:GetFullName(),
					baseFolder.ClassName,
					table.concat(childNames, ', ')
				))
			local probe = baseFolder:FindFirstChild('Collector')
			if probe == nil then
				Debug.Log('BaseService', ('Base=%s Collector instance=nil'):format(id))
			else
				local isPart = probe:IsA('BasePart')
								Debug.Log('BaseService', ('Base=%s Collector instance=%s class=%s IsABasePart=%s'):format(
						id,
						probe:GetFullName(),
						probe.ClassName,
						tostring(isPart)
					))
				if isPart then
					local probePart = probe :: BasePart
										Debug.Log('BaseService', ('Base=%s Collector Anchored=%s CanTouch=%s CanCollide=%s'):format(
							id,
							tostring(probePart.Anchored),
							tostring(probePart.CanTouch),
							tostring(probePart.CanCollide)
						))
				end
			end
		end

		-- Spawn part.
		local spawn = baseFolder:FindFirstChild('Spawn')
		if not spawn then
			spawn = Instance.new('Part')
			spawn.Name = 'Spawn'
			spawn.Size = Vector3.new(6, 1, 6)
			spawn.Anchored = true
			spawn.Material = Enum.Material.SmoothPlastic
			spawn.BrickColor = BrickColor.new('Medium stone grey')
			spawn.CFrame = CFrame.new(i * 40, 0.5, 0)
			spawn.Parent = baseFolder
		end

		-- Player spawn ownership: the assigned base determines
		-- the player's spawn. Roblox respawns natively at
		-- player.RespawnLocation, which must be a SpawnLocation
		-- instance — so every base owns exactly one, derived
		-- deterministically from the authored `Spawn` part
		-- above (same CFrame). A Studio-authored
		-- `SpawnLocation` child is reused as-is (map intent
		-- wins); otherwise one is created here at boot, never
		-- at runtime. Stored on the base record; bootstrap +
		-- reassign paths point the owner at it BEFORE the
		-- character loads, so BaseService (not a separate
		-- spawn picker) is the single authority for player
		-- spawn, on join AND on every respawn.
		local spawnLocation = baseFolder:FindFirstChild('SpawnLocation')
		if spawnLocation ~= nil and not spawnLocation:IsA('SpawnLocation') then
			Debug.Warn('BaseService', 
					tostring(id)
				)
			spawnLocation = nil
		end
		if spawnLocation == nil then
			local pad = Instance.new('SpawnLocation')
			pad.Name = 'SpawnLocation'
			pad.Size = Vector3.new(6, 1, 6)
			pad.CFrame = spawn.CFrame
			pad.Anchored = true
			pad.CanCollide = false
			pad.CanQuery = false
			pad.CanTouch = false
			pad.Neutral = false
			pad.Enabled = true
			pad.AllowTeamChangeOnTouch = false
			pad.Parent = baseFolder
			spawnLocation = pad
		end

		-- The base's Collector part and the yaw-only CFrame
		-- pointing at it. Never nil: `_resolveCollector`
		-- errors out when the asset is missing, the wrong
		-- class, or degenerately placed. Every slot's
		-- rotation is set to this facing so placed items face
		-- the Collector. Both are stashed on the base record
		-- so the Egg / animal services can read the
		-- facing for their place math (roll previews, flight
		-- destinations) without re-walking the Workspace tree.
		local collector, collectorFacing = _resolveCollector(baseFolder, spawn.CFrame.Position)

		-- Dynamic runtime slots (MAIN GAME, StandPos
		-- architecture). When the base carries static
		-- `StandPos/StandPos<k>` markers, NO slots are created
		-- here: an unassigned base holds ZERO runtime slots.
		-- Clones are built from the ServerStorage template on
		-- assignment (see DynamicSlotService) and destroyed on
		-- release, so a new owner can never inherit state.
		local standPosMarkers = StandResolver.GetStandPosSorted(baseFolder)
		local stands = StandResolver.GetStandsSorted(baseFolder)
		local slots: { [number]: any } = {}
		local isDynamic = #standPosMarkers > 0
		if isDynamic then
			-- Gap check (once per boot, loud): a missing
			-- StandPos<k> in 1..max leaves that slot absent.
			-- Indices never shift — StandPos3 always means
			-- slot 3 — so a gap is a hole, not a renumber.
			local maxMarker = 0
			local seen: { [number]: boolean } = {}
			for _, marker in ipairs(standPosMarkers) do
				local idx = StandResolver.ParseStandPosIndex(marker.Name) :: number
				seen[idx] = true
				if idx > maxMarker then
					maxMarker = idx
				end
			end
			for n = 1, maxMarker do
				if not seen[n] then
					warn(
						('[DynamicSlots] Base %s missing StandPos%d (expected %s.StandPos.StandPos%d)'):format(
							id,
							n,
							baseFolder:GetFullName(),
							n
						)
					)
				end
			end
			-- Arena markers use the same gap rule (holes, never
			-- renumbers); checked once per boot, same as Slots.
			local arenaMarkers = StandResolver.GetArenaStandPosSorted(baseFolder)
			local arenaMax = 0
			local arenaSeen: { [number]: boolean } = {}
			for _, marker in ipairs(arenaMarkers) do
				local idx = StandResolver.ParseArenaStandPosIndex(marker.Name) :: number
				arenaSeen[idx] = true
				if idx > arenaMax then
					arenaMax = idx
				end
			end
			for n = 1, arenaMax do
				if not arenaSeen[n] then
					warn(
						('[DynamicArenaStands] Base %s missing ArenaStandPos%d (expected %s.ArenaStandPos.ArenaStandPos%d)'):format(
							id,
							n,
							baseFolder:GetFullName(),
							n
						)
					)
				end
			end
			Debug.Log('BS', 'RegisterBases: dynamic slot mode', { id = id, markers = #standPosMarkers })
		elseif #stands > 0 then
			for _, stand in ipairs(stands) do
				local standIndex = StandResolver.ParseStandIndex(stand.Name) :: number
				local parts = StandResolver.GetStandParts(stand)
				if parts.root == nil then
										Debug.Warn('BaseService', ('%s has no usable Slot.Root; slot %d registers without a part'):format(
							stand:GetFullName(),
							standIndex
						))
				end
				if parts.pressPart == nil then
										Debug.Warn('BaseService', ('%s has no Button.PressPart; slot %d registers without a cash trigger'):format(
							stand:GetFullName(),
							standIndex
						))
				end
				slots[standIndex] = {
					id = SlotType.BuildId(0, SlotType.Kind.Slot, standIndex),
					ownerUserId = 0,
					baseId = id,
					kind = SlotType.Kind.Slot,
					index = standIndex,
					state = SlotType.State.Empty,
					occupantId = nil,
					occupantKind = nil,
					_mutex = false,
					part = parts.root,
					cashCollector = parts.pressPart,
					stand = stand,
					standIndex = standIndex,
					offset = Bases.Slots.Offsets[standIndex] or Vector3.new(0, 2, 0),
				}
			end
			-- A Studio file with fewer stands than SlotCount
			-- still registers part-less records for the missing
			-- indices so snapshots stay dense and missing
			-- stands are LOUD instead of silently shifting
			-- every higher stand down an index (which would
			-- corrupt the Stand<->slot mapping persistence
			-- relies on). Nothing is auto-created.
			for n = 1, Bases.Slots.Count do
				if slots[n] == nil then
					warn(
						('[BaseService] %s.AnimalStands.Stand%d is missing; slot %d has no stand'):format(
							baseFolder:GetFullName(),
							n,
							n
						)
					)
					slots[n] = {
						id = SlotType.BuildId(0, SlotType.Kind.Slot, n),
						ownerUserId = 0,
						baseId = id,
						kind = SlotType.Kind.Slot,
						index = n,
						state = SlotType.State.Empty,
						occupantId = nil,
						occupantKind = nil,
						_mutex = false,
						part = nil,
						cashCollector = nil,
						stand = nil,
						standIndex = n,
						offset = Bases.Slots.Offsets[n] or Vector3.new(0, 2, 0),
					}
				end
			end
		else
			-- Legacy fallback (no AnimalStands: bare test/dev
			-- workspaces). Preserved verbatim from the prior
			-- unified-`Slots` behavior.
			-- Unified `Slots` folder + child parts. Phase 2: all
			-- SlotCount slots live under one folder. The part
			-- color is neutral at creation; the server re-tints
			-- per occupant kind on `OccupySlot`.
			local slotsFolder = baseFolder:FindFirstChild('Slots')
			if not slotsFolder then
				slotsFolder = Instance.new('Folder')
				slotsFolder.Name = 'Slots'
				slotsFolder.Parent = baseFolder
			end
			for n = 1, Bases.Slots.Count do
				local slotPart = slotsFolder:FindFirstChild('Slot' .. tostring(n))
				if not slotPart then
					slotPart = Instance.new('Part')
					slotPart.Name = 'Slot' .. tostring(n)
					slotPart.Size = Bases.Slots.Size
					slotPart.Anchored = true
					slotPart.Material = Enum.Material.SmoothPlastic
					slotPart.BrickColor = BrickColor.new('Medium stone grey')
					local offset = Bases.Slots.Offsets[n] or Vector3.new(0, 2, 0)
					-- The slot's POSITION is the grid offset from
					-- Spawn (so the slot grid stays where the
					-- designer / Spawn-offset math expects it).
					-- The rotation is always the Collector-facing
					-- Yaw so placed items face the Collector.
					local slotPos = spawn.CFrame + offset
					slotPart.CFrame = CFrame.new(slotPos.Position) * collectorFacing
					slotPart.Parent = slotsFolder
				else
					-- Pre-existing slot (Studio-authored). Update
					-- only the Yaw so the slot rotates to face
					-- the Collector on the next server start.
					-- The position stays wherever Studio
					-- placed it; only the Yaw is changed.
					slotPart.CFrame = CFrame.new(slotPart.CFrame.Position) * collectorFacing
				end
				slots[n] = {
					id = SlotType.BuildId(0, SlotType.Kind.Slot, n),
					ownerUserId = 0,
					baseId = id,
					kind = SlotType.Kind.Slot,
					index = n,
					state = SlotType.State.Empty,
					occupantId = nil,
					occupantKind = nil,
					_mutex = false,
					part = slotPart,
					-- Phase 2.6: the slot's cash trigger volume (created
					-- or reused above); IncomeService attaches ONE
					-- Touched connection per part.
					cashCollector = _ensureCashCollector(slotPart),
					stand = nil,
					standIndex = n,
					offset = Bases.Slots.Offsets[n] or Vector3.new(0, 2, 0),
				}
			end
		end

		local base: any = {
			id = id,
			index = i,
			state = BaseType.State.Available,
			ownerUserId = nil,
			-- Ownership session: bumped on EVERY assign and EVERY
			-- release/cleanup/wipe. Stale owner-specific callbacks
			-- must compare against GetSession before mutating.
			session = 0,
			-- Dynamic slots: true when this base builds runtime
			-- Stand<k> clones from StandPos markers on assign
			-- (zero slots while unassigned).
			dynamicSlots = isDynamic,
			standPosCount = #standPosMarkers,
			spawnCFrame = spawn.CFrame,
			-- The base's SpawnLocation instance (authored or
			-- ensured above). The owner's player.RespawnLocation
			-- points here; see PointPlayerToBaseSpawn.
			spawnLocation = spawnLocation,
			collector = collector,
			collectorFacing = collectorFacing,
			folder = baseFolder,
			slots = slots,
			-- Arena runtime slot records (built by
			-- DynamicSlotService.BuildArenaStands on assign;
			-- empty while unassigned). Kept OUTSIDE `slots`
			-- so capacity, HUD snapshots, and egg placement
			-- (all `base.slots` readers) stay normal-only.
			-- Income, upgrades, sales, menus, and stealing
			-- resolve through SlotService and treat arena
			-- stands as first-class animal slots.
			arenaSlots = {},
			_mutex = false,
			_occupiedCount = 0,
		}
		bases[id] = base
		if slotServiceRef then
			slotServiceRef.RegisterBase(base)
		end
		Debug.Log('BS', 'RegisterBases: base created', { id = id, spawnCFrame = tostring(base.spawnCFrame) })
	end
	-- Dynamic-mode startup signal: resolve the Slot template
	-- once when at least one base needs it. A missing template
	-- warns here (actionable, at boot) AND fails each affected
	-- base closed at assign time.
	local anyDynamic = false
	local anyArena = false
	for _, base in pairs(bases) do
		if base.dynamicSlots then
			anyDynamic = true
		end
		if #StandResolver.GetArenaStandPosSorted(base.folder) > 0 then
			anyArena = true
		end
		if anyDynamic and anyArena then
			break
		end
	end
	if anyDynamic then
		pcall(DynamicSlotService.GetTemplate)
	end
	if anyArena then
		pcall(DynamicSlotService.GetArenaTemplate)
	end
	-- MAIN GAME: every base starts unowned, so every
	-- multiplier label starts hidden. Lazy require: Rebirth
	-- owns the label painter and requires BaseService.
	local okRebBoot, rebBootSvc = pcall(require, script.Parent.Rebirth.RebirthService)
	if okRebBoot and rebBootSvc and rebBootSvc.HideAllBaseMultipliers then
		pcall(rebBootSvc.HideAllBaseMultipliers)
	end
	Debug.Log('BS', '< RegisterBases done')
end

-- --- Base lookup --------------------------------------------------

function BaseService.GetBaseById(baseId: string): any?
	Validation.ShortString(baseId)
	return bases[baseId]
end

function BaseService.GetBaseByOwner(userId: number): any?
	Validation.PositiveInteger(userId)
	local bid = basesByOwner[userId]
	if not bid then
		return nil
	end
	return bases[bid]
end

function BaseService.GetPlayerBase(userId: number): any?
	return BaseService.GetBaseByOwner(userId)
end

-- Ownership helper (spec §28 API). One-liner over the
-- existing registry; centralized so the prompt callback
-- doesn't have to know the base lookup shape.
function BaseService.IsBaseOwnedByPlayer(baseId: string, userId: number): boolean
	if not baseId or type(baseId) ~= 'string' or type(userId) ~= 'number' then
		return false
	end
	local base = bases[baseId]
	return base ~= nil and base.ownerUserId == userId
end

function BaseService.GetBaseState(baseId: string): string?
	local b = bases[baseId]
	if not b then
		return nil
	end
	return b.state
end

function BaseService.GetAllBases(): { [string]: any }
	return bases
end

-- --- Ownership sessions + lifecycle validation ----------------------

-- Current ownership session for a base (0 = never assigned).
-- Every assign AND every release/cleanup/wipe bumps it, so a
-- callback holding an older number is provably stale.
function BaseService.GetSession(baseId: string): number?
	local base = bases[baseId]
	if not base then
		return nil
	end
	return base.session or 0
end

-- Fencing helper for owner-specific async work (delayed tasks,
-- tween completions, deferred refreshes). Returns true iff
-- `session` is still the base's live session. On mismatch warns
-- with both numbers and returns false — the caller must mutate
-- nothing.
function BaseService.IsCurrentSession(baseId: string, session: number): boolean
	local base = bases[baseId]
	if not base then
		return false
	end
	if (base.session or 0) ~= session then
				Debug.Warn('BaseLifecycle', ('[WARN] stale callback ignored base=%s callbackSession=%s currentSession=%s'):format(
				tostring(baseId),
				tostring(session),
				tostring(base.session or 0)
			))
		return false
	end
	return true
end

local function _bumpSession(base: any)
	base.session = (base.session or 0) + 1
end

-- Shared owner-state teardown: slot reset (+ stuck-mutex clear),
-- slot-part prompt sweep, prompt-registry purge, and display
-- repaint (pool + stand hooks) so an unassigned base is
-- genuinely EMPTY — no occupancy, no owner refs, no live
-- prompts, no stale amounts on collectors/buttons.
-- Must run BEFORE ClearBaseOwner/UnregisterBase (the repaint
-- resolves slots through SlotService). Never throws: every
-- step is pcall-guarded WITH a warn (§45 — a silent partial
-- cleanup is worse than a loud one). Persistence untouched.
local function _resetSlotsAndSweep(base: any, reason: string)
	-- Normal + arena records share the reset: an arena slot
	-- holding a previous owner's animal must never survive
	-- teardown (the persisted record keeps the animal; the
	-- runtime slot goes Empty/owner-0 like every other slot).
	local allSlots: { any } = {}
	for _, slot in pairs(base.slots) do
		allSlots[#allSlots + 1] = slot
	end
	if type(base.arenaSlots) == 'table' then
		for _, slot in pairs(base.arenaSlots) do
			allSlots[#allSlots + 1] = slot
		end
	end
	for _, slot in pairs(allSlots) do
		local ok, err = pcall(function()
			slot.state = SlotType.State.Empty
			slot.occupantId = nil
			slot.occupantKind = nil
			slot.ownerUserId = 0
			slot.id = SlotType.BuildId(0, SlotType.Kind.Slot, slot.index)
			slot._mutex = false
		end)
		if not ok then
			warn(
				('[BaseLifecycle][WARN] Base=%s slot reset failed (%s): %s'):format(
					tostring(base.id),
					tostring(reason),
					tostring(err)
				)
			)
		end
	end
	for _, slot in pairs(allSlots) do
		local ok, err = pcall(function()
			if slot.part then
				for _, child in ipairs((slot.part :: Instance):GetChildren()) do
					if child:IsA('ProximityPrompt') then
						child:Destroy()
					end
				end
			end
		end)
		if not ok then
			warn(
				('[BaseLifecycle][WARN] Base=%s prompt sweep failed (%s): %s'):format(
					tostring(base.id),
					tostring(reason),
					tostring(err)
				)
			)
		end
	end
	local okReg, errReg = pcall(function()
		local CarryPrompts = require(script.Parent.Animal.CarryPrompts)
		if CarryPrompts and CarryPrompts.ForgetSlotsForBase then
			-- Covers normal + arena records (single call).
			CarryPrompts.ForgetSlotsForBase(base)
		end
	end)
	if not okReg then
		warn(
			('[BaseLifecycle][WARN] Base=%s prompt-registry purge failed (%s): %s'):format(
				tostring(base.id),
				tostring(reason),
				tostring(errReg)
			)
		)
	end
	if slotServiceRef then
		for _, slot in pairs(allSlots) do
			local ok, result = pcall(slotServiceRef.RefreshDisplays, slot.id)
			if not ok or result == false then
								Debug.Warn('BaseLifecycle', ('[WARN] Base=%s display repaint missed slot=%s (%s)'):format(
						tostring(base.id),
						tostring(slot.id),
						tostring(reason)
					))
			end
		end
		pcall(slotServiceRef.ClearMenuWarnings)
	end
end

-- Debug invariant (§40): verifies a base carries no foreign
-- runtime state. Returns true when clean; warns per problem
-- (never spammy — called on assign/release/cleanup only).
-- Unassigned expectation: owner nil, Available, slots
-- Empty/owner 0/zero-stamped, no slot-part prompts, no stuck
-- mutex. Assigned expectation: owner set, every slot stamped
-- to the owner, no zero-stamped slots, no foreign prompts.
function BaseService.ValidateBaseRuntime(baseId: string): boolean
	local base = bases[baseId]
	if not base then
		warn(('[BaseLifecycle][WARN] Base=%s unknown to validator'):format(tostring(baseId)))
		return false
	end
	local clean = true
	local function flag(message: string)
		clean = false
				Debug.Warn('BaseLifecycle', ('[WARN] Base=%s session=%s %s'):format(
				tostring(base.id),
				tostring(base.session or 0),
				message
			))
	end
	if base.ownerUserId == nil then
		if base.state ~= BaseType.State.Available then
			flag(('unassigned but state=%s (expected Available)'):format(tostring(base.state)))
		end
	else
		if base.state == BaseType.State.Available then
			flag(('owned by %s but state=Available'):format(tostring(base.ownerUserId)))
		end
	end
	for _, slot in pairs(base.slots) do
		if base.ownerUserId == nil then
			if slot.state ~= SlotType.State.Empty then
				flag(
					('slot=%s has state=%s while base is unassigned'):format(tostring(slot.index), tostring(slot.state))
				)
			end
			if slot.occupantId ~= nil or slot.occupantKind ~= nil then
				flag(('slot=%s has runtime occupant while base is unassigned'):format(tostring(slot.index)))
			end
			if slot.ownerUserId ~= 0 then
				flag(
					('slot=%s owner=%s while base is unassigned'):format(
						tostring(slot.index),
						tostring(slot.ownerUserId)
					)
				)
			end
		else
			if slot.ownerUserId ~= base.ownerUserId then
				flag(
					('slot=%s owner=%s does not match base owner=%s'):format(
						tostring(slot.index),
						tostring(slot.ownerUserId),
						tostring(base.ownerUserId)
					)
				)
			end
		end
		if slot._mutex == true then
			flag(('slot=%s has stuck _mutex'):format(tostring(slot.index)))
		end
		local ok, prompts = pcall(function()
			local found = 0
			if slot.part then
				for _, child in ipairs((slot.part :: Instance):GetChildren()) do
					if child:IsA('ProximityPrompt') then
						found += 1
					end
				end
			end
			return found
		end)
		if ok and (prompts :: number) > 0 and base.ownerUserId == nil then
			flag(
				('slot=%s has %s live prompt(s) while base is unassigned'):format(
					tostring(slot.index),
					tostring(prompts)
				)
			)
		end
	end
	-- Dynamic mode: the AnimalStands folder must hold runtime
	-- Slot<k> clones exactly while assigned, and ZERO of them
	-- while unassigned. StandPos markers live in the separate
	-- StandPos folder and are never counted here.
	if base.dynamicSlots then
		local okStands, standCount = pcall(function()
			local count = 0
			local folder = base.folder
			if typeof(folder) ~= 'Instance' then
				return 0
			end
			local standsFolder = folder:FindFirstChild(StandResolver.Names.StandsFolder)
			if standsFolder == nil then
				return 0
			end
			for _, child in ipairs((standsFolder :: Instance):GetChildren()) do
				if StandResolver.ParseSlotIndex(child.Name) ~= nil then
					count += 1
				end
			end
			return count
		end)
		if okStands then
			if base.ownerUserId == nil and (standCount :: number) > 0 then
				flag(('has %s runtime Slot clone(s) while unassigned (expected ZERO)'):format(tostring(standCount)))
			end
		else
			flag('could not enumerate AnimalStands for clone check')
		end
	end
	-- Arena stands (independent track): an unassigned base must
	-- hold ZERO ArenaStand<k> clones in ArenaAnimalStands. Only
	-- checked when the marker folder exists (bases without an
	-- arena setup skip silently).
	if base.ownerUserId == nil then
		local okArena, arenaCount = pcall(function()
			local count = 0
			local folder = base.folder
			if typeof(folder) ~= 'Instance' then
				return -1
			end
			if folder:FindFirstChild(StandResolver.Names.ArenaStandPosFolder) == nil then
				return -1
			end
			local container = folder:FindFirstChild(StandResolver.Names.ArenaStandsFolder)
			if container == nil then
				return 0
			end
			for _, child in ipairs((container :: Instance):GetChildren()) do
				if StandResolver.ParseArenaStandIndex(child.Name) ~= nil then
					count += 1
				end
			end
			return count
		end)
		if okArena and (arenaCount :: number) > 0 then
			flag(('has %s runtime ArenaStand clone(s) while unassigned (expected ZERO)'):format(tostring(arenaCount)))
		elseif not okArena then
			flag('could not enumerate ArenaAnimalStands for clone check')
		end
	end
	return clean
end

-- --- Base assignment ---------------------------------------------

function BaseService.AssignBaseForPlayer(userId: number): any?
	Debug.Log('BS', '> AssignBaseForPlayer', { userId = tostring(userId) })
	Validation.PositiveInteger(userId)
	if basesByOwner[userId] then
		Debug.Log('BS', 'AssignBaseForPlayer: already has base', { baseId = basesByOwner[userId] })
		return bases[basesByOwner[userId]]
	end
	for _, base in pairs(bases) do
		Debug.Log(
			'BS',
			'AssignBaseForPlayer: scanning base',
			{ id = base.id, state = tostring(base.state), mutex = tostring(base._mutex) }
		)
		if base.state == BaseType.State.Available and not base._mutex then
			-- Never inherit: an Available base must be runtime-clean
			-- before a new owner touches it. If a previous release
			-- left dirt, warn loudly and canonically clean first.
			if not BaseService.ValidateBaseRuntime(base.id) then
								Debug.Warn('BaseLifecycle', ('[WARN] Base=%s dirty at assign; cleaning before owner=%s'):format(
						tostring(base.id),
						tostring(userId)
					))
				_resetSlotsAndSweep(base, 'assign-scrub')
			end
			base._mutex = true
			basesByOwner[userId] = base.id
			base.ownerUserId = userId
			base.state = BaseType.State.Reserved
			_bumpSession(base)

			-- Re-stamp slot ids with the new owner's userId.
			for _, slot in pairs(base.slots) do
				slot.ownerUserId = userId
				slot.id = SlotType.BuildId(userId, SlotType.Kind.Slot, slot.index)
			end
			-- Arena records re-stamp identically (stale arena
			-- ids from the previous owner must never resolve).
			if type(base.arenaSlots) == 'table' then
				for _, slot in pairs(base.arenaSlots) do
					slot.ownerUserId = userId
					slot.id = SlotType.BuildId(userId, SlotType.Kind.Slot, slot.index)
				end
			end
			if base.dynamicSlots then
				-- Dynamic mode: build runtime Slot<k> clones
				-- from StandPos markers, then re-index
				-- SlotService (Unregister+Register is the
				-- idempotent pair for a replaced slot table).
				DynamicSlotService.BuildBaseSlots(base, userId, base.session)
				-- Cash triggers live on the fresh clones:
				-- attach the ONE Touched connection per new
				-- collector part (idempotent; legacy parts
				-- were wired at IncomeService.Start). Arena
				-- collectors wire inside BuildArenaStands
				-- itself (records must exist first) — NOT
				-- here, which runs before the arena build.
				local okInc, incSvc = pcall(require, script.Parent.IncomeService)
				if okInc and incSvc and incSvc.EnsureCollectorsForSlots then
					pcall(incSvc.EnsureCollectorsForSlots, base.slots)
				end
			end
			-- Arena stands (independent track): build whenever
			-- the base carries ArenaStandPos markers, whether
			-- or not the Slot track is dynamic. Silent skip
			-- when no markers exist (legacy/spec bases).
			if #DynamicSlotService.GetArenaStandPositions(base.folder) > 0 then
				DynamicSlotService.BuildArenaStands(base, userId, base.session)
			end
			if slotServiceRef then
				if base.dynamicSlots then
					slotServiceRef.UnregisterBase(base.id)
					slotServiceRef.RegisterBase(base)
				end
				slotServiceRef.SetBaseOwner(userId, base)
				slotServiceRef.RebaseSlotIds(base)
				-- Paint the new owner's (empty) state immediately:
				-- pool + stand displays must never show the
				-- previous owner's amounts.
				for _, slot in pairs(base.slots) do
					pcall(slotServiceRef.RefreshDisplays, slot.id)
				end
				if type(base.arenaSlots) == 'table' then
					for _, slot in pairs(base.arenaSlots) do
						pcall(slotServiceRef.RefreshDisplays, slot.id)
					end
				end
			end

			-- MAIN GAME: reflect the new owner on the Studio
			-- PlayerBoard (display-only; ownership stays here).
			-- Nil-safe when the Player object is absent.
			PlayerBoard.Refresh(base.folder, Players:GetPlayerByUserId(userId))

			-- MAIN GAME: the new owner's CURRENT multiplier shows
			-- on their Base's MoneyMultPart label immediately (no
			-- stale previous-owner value). Lazy require: Rebirth
			-- owns the label painter and requires BaseService.
			local okReb, rebSvc = pcall(require, script.Parent.Rebirth.RebirthService)
			if okReb and rebSvc and rebSvc.RefreshBaseMultiplier then
				pcall(rebSvc.RefreshBaseMultiplier, userId)
			end

			-- MAIN GAME: fresh assignment carries no lock. Notify the
			-- lock service so a stale owner-group can never linger.
			if baseLockServiceRef then
				pcall(function()
					baseLockServiceRef.HandleBaseAssigned(userId)
				end)
			end

			base._mutex = false
			BaseService.ValidateBaseRuntime(base.id)
			Debug.Log('BS', 'AssignBaseForPlayer: assigned', { userId = tostring(userId), baseId = base.id })
			return base
		end
	end
	Debug.Log('BS', 'AssignBaseForPlayer: no available base, returning nil')
	return nil
end

-- Spawn ownership: point a player at their assigned base's
-- SpawnLocation BEFORE the character loads. This is the ONE
-- authoritative RespawnLocation assignment for normal player
-- spawn — join, rebirth, and admin wipe/reset all funnel
-- through here, so BaseService (via the assigned base) is what
-- determines spawn, never a separate spawn picker. Returns true
-- on success; on any failure returns false and leaves any
-- previous RespawnLocation untouched (callers must NOT call
-- LoadCharacter in that case).
function BaseService.PointPlayerToBaseSpawn(player: Player, base: any): boolean
	if typeof(player) ~= 'Instance' or not player:IsA('Player') then
		return false
	end
	if type(base) ~= 'table' or type(base.id) ~= 'string' then
		return false
	end
	local pad = (base :: any).spawnLocation
	if typeof(pad) ~= 'Instance' or not (pad :: Instance):IsA('SpawnLocation') then
		Debug.Warn('BaseService', tostring(base.id))
		return false
	end
	if (pad :: Instance).Parent == nil then
		Debug.Warn('BaseService', tostring(base.id))
		return false
	end
	player.RespawnLocation = pad :: SpawnLocation
	Debug.Log('BS', 'PointPlayerToBaseSpawn', { userId = tostring(player.UserId), baseId = base.id })
	return true
end

function BaseService.AssignBaseById(userId: number, baseId: string): any?
	Validation.PositiveInteger(userId)
	Validation.ShortString(baseId)
	local base = bases[baseId]
	if not base or base.state ~= BaseType.State.Available or base._mutex then
		return nil
	end
	if basesByOwner[userId] then
		return nil
	end
	if not BaseService.ValidateBaseRuntime(baseId) then
				Debug.Warn('BaseLifecycle', ('[WARN] Base=%s dirty at assign; cleaning before owner=%s'):format(
				tostring(baseId),
				tostring(userId)
			))
		local dirty = bases[baseId]
		if dirty then
			_resetSlotsAndSweep(dirty, 'assign-scrub')
		end
	end
	base._mutex = true
	basesByOwner[userId] = baseId
	base.ownerUserId = userId
	base.state = BaseType.State.Reserved
	_bumpSession(base)
	for _, slot in pairs(base.slots) do
		slot.ownerUserId = userId
		slot.id = SlotType.BuildId(userId, SlotType.Kind.Slot, slot.index)
	end
	if type(base.arenaSlots) == 'table' then
		for _, slot in pairs(base.arenaSlots) do
			slot.ownerUserId = userId
			slot.id = SlotType.BuildId(userId, SlotType.Kind.Slot, slot.index)
		end
	end
	if base.dynamicSlots then
		-- Dynamic mode: build runtime Slot<k> clones from
		-- StandPos markers, then re-index SlotService.
		DynamicSlotService.BuildBaseSlots(base, userId, base.session)
		local okInc, incSvc = pcall(require, script.Parent.IncomeService)
		if okInc and incSvc and incSvc.EnsureCollectorsForSlots then
			pcall(incSvc.EnsureCollectorsForSlots, base.slots)
		end
	end
	-- Arena stands (independent track, silent skip without markers).
	if #DynamicSlotService.GetArenaStandPositions(base.folder) > 0 then
		DynamicSlotService.BuildArenaStands(base, userId, base.session)
	end
	if slotServiceRef then
		if base.dynamicSlots then
			slotServiceRef.UnregisterBase(base.id)
			slotServiceRef.RegisterBase(base)
		end
		slotServiceRef.SetBaseOwner(userId, base)
		slotServiceRef.RebaseSlotIds(base)
		for _, slot in pairs(base.slots) do
			pcall(slotServiceRef.RefreshDisplays, slot.id)
		end
		if type(base.arenaSlots) == 'table' then
			for _, slot in pairs(base.arenaSlots) do
				pcall(slotServiceRef.RefreshDisplays, slot.id)
			end
		end
	end
	-- MAIN GAME: reflect the new owner on the Studio
	-- PlayerBoard (display-only; ownership stays here).
	PlayerBoard.Refresh(base.folder, Players:GetPlayerByUserId(userId))
	-- MAIN GAME: the new owner's CURRENT multiplier shows
	-- on their Base's MoneyMultPart label immediately (no
	-- stale previous-owner value). Lazy require: Rebirth
	-- owns the label painter and requires BaseService.
	local okReb2, rebSvc2 = pcall(require, script.Parent.Rebirth.RebirthService)
	if okReb2 and rebSvc2 and rebSvc2.RefreshBaseMultiplier then
		pcall(rebSvc2.RefreshBaseMultiplier, userId)
	end
	-- MAIN GAME: fresh assignment carries no lock.
	if baseLockServiceRef then
		pcall(function()
			baseLockServiceRef.HandleBaseAssigned(userId)
		end)
	end
	base._mutex = false
	BaseService.ValidateBaseRuntime(baseId)
	return base
end

function BaseService.ReleasePlayerBase(userId: number): boolean
	Validation.PositiveInteger(userId)
	local bid = basesByOwner[userId]
	if not bid then
		return false
	end
	return BaseService.ReleaseBase(bid, userId)
end

function BaseService.ReleaseBase(baseId: string, expectedUserId: number?): boolean
	Validation.ShortString(baseId)
	local base = bases[baseId]
	if not base then
		return false
	end
	if expectedUserId ~= nil and base.ownerUserId ~= expectedUserId then
		return false
	end
	if base._mutex then
		return false
	end
	base._mutex = true

	-- MAIN GAME: never leave a released base locked. Unlock first
	-- so laser visuals, collision groups, and the timer reset
	-- before ownership is torn down.
	if baseLockServiceRef then
		pcall(function()
			baseLockServiceRef.HandleBaseReleased(baseId)
		end)
	end

	-- MAIN GAME: the board must not keep showing the previous
	-- owner once the base is released.
	PlayerBoard.Clear(base.folder)

	-- MAIN GAME: the multiplier label must not keep showing
	-- the previous owner's value either. Ownership is still
	-- intact here, so the owner-gated hide resolves.
	local okRebHide, rebHideSvc = pcall(require, script.Parent.Rebirth.RebirthService)
	if okRebHide and rebHideSvc and rebHideSvc.HideBaseMultiplier then
		local hideFor = base.ownerUserId
		if type(hideFor) == 'number' then
			pcall(rebHideSvc.HideBaseMultiplier, hideFor)
		end
	end

	-- Tell other services to clear anything they had living on this base.
	if eggServiceRef then
		eggServiceRef.ForceReleaseBase(baseId)
	end
	if animalServiceRef then
		animalServiceRef.ForceReleaseBase(baseId)
	end

	-- Full owner-state teardown (slots, prompts, prompt
	-- registry, display repaint) BEFORE ownership is cleared,
	-- so cleanup systems still see who owned what.
	-- Dynamic mode: destroy the runtime Slot<k> clones FIRST
	-- (registrations die with them; StandPos markers and the
	-- shell are untouched).
	if base.dynamicSlots then
		DynamicSlotService.DestroyBaseSlots(base, base.session)
	end
	-- Arena stands (independent track; silent no-op when the
	-- base never built any).
	DynamicSlotService.DestroyArenaStands(base, base.session)
	_resetSlotsAndSweep(base, 'release')
	base._occupiedCount = 0

	if base.ownerUserId then
		basesByOwner[base.ownerUserId] = nil
		if slotServiceRef then
			slotServiceRef.ClearBaseOwner(base.ownerUserId)
		end
		if playerServiceRef then
			playerServiceRef.ReleaseBase(base.ownerUserId)
		end
	end
	base.ownerUserId = nil
	base.state = BaseType.State.Available
	_bumpSession(base)

	if slotServiceRef then
		slotServiceRef.UnregisterBase(baseId)
	end
	base._mutex = false
	BaseService.ValidateBaseRuntime(baseId)
	return true
end

-- --- Slot primitives (Phase 3 pass-throughs) ---------------------
--
-- Phase 3: every method in this egg routes through
-- SlotService. BaseService keeps the surface for one release
-- so existing call sites keep compiling; each pass-through
-- logs a deprecation warning. Phase 3 finishes when every
-- caller in `EggService` / `AnimalService` /
-- `SlotActionHandler` / `SpawnService` calls
-- `slotServiceRef.*` directly and the pass-throughs are
-- removed.

local function deprecate(method: string)
	Debug.Log('BS', 'DEPRECATION: ' .. method .. ' called via BaseService; route to SlotService instead')
end

function BaseService.GetFreeSlot(userId: number): any?
	deprecate('GetFreeSlot')
	if slotServiceRef then
		return slotServiceRef.GetFreeSlot(userId)
	end
	return nil
end

-- Deprecated. Phase 4 removes this and the Place prompt
-- moves to slot parts.
function BaseService.GetNearestValidSlotForPlayer(userId: number, playerPos: Vector3): any?
	deprecate('GetNearestValidSlotForPlayer')
	if slotServiceRef then
		return slotServiceRef.GetNearestValidSlotForPlayer(userId, playerPos)
	end
	return nil
end

function BaseService.ReserveSlot(slotId: string): boolean
	deprecate('ReserveSlot')
	if slotServiceRef then
		return slotServiceRef.ReserveSlot(slotId)
	end
	return false
end

function BaseService.DemoteSlotToReserved(slotId: string): boolean
	deprecate('DemoteSlotToReserved')
	if slotServiceRef then
		return slotServiceRef.DemoteSlotToReserved(slotId)
	end
	return false
end

function BaseService.OccupySlot(slotId: string, occupantId: string, occupantKind: string?): boolean
	deprecate('OccupySlot')
	if slotServiceRef then
		return slotServiceRef.OccupySlot(slotId, occupantId, occupantKind)
	end
	return false
end

function BaseService.ReleaseSlot(slotId: string): boolean
	deprecate('ReleaseSlot')
	if slotServiceRef then
		return slotServiceRef.ReleaseSlot(slotId)
	end
	return false
end

function BaseService.FindSlotByOccupant(occupantId: string): (any?, any?)
	deprecate('FindSlotByOccupant')
	if slotServiceRef then
		return slotServiceRef.FindSlotByOccupant(occupantId)
	end
	return nil, nil
end

function BaseService._findSlotById(slotId: string): any?
	if slotServiceRef then
		return slotServiceRef._findSlotById(slotId)
	end
	-- Pre-Phase-3 fallback (no SlotService wired): the
	-- original ParseId-based lookup. Only used by tests
	-- that exercise BaseService in isolation.
	local parsed = SlotType.ParseId(slotId)
	if not parsed then
		Debug.Warn('BS', '_findSlotById: ParseId failed for slotId', { slotId = slotId })
		return nil
	end
	local userId = parsed.userId
	local index = parsed.index
	for _, base in pairs(bases) do
		if base.ownerUserId == userId then
			local s = base.slots[index]
			if s and s.id == slotId then
				return s
			end
		end
	end
	Debug.Warn('BS', '_findSlotById: no slot matched', { slotId = slotId })
	return nil
end

function BaseService.ReleaseReservedSlotForUser(userId: number, index: number): boolean
	deprecate('ReleaseReservedSlotForUser')
	if slotServiceRef then
		return slotServiceRef.ReleaseReservedSlotForUser(userId, index)
	end
	return false
end

-- Rejoin restoration. PlayerService calls this AFTER
-- LoadPlayerData + AssignBase, so the base is already in the
-- registry and slot ids are already stamped with the user's
-- id. We:
--   1. Reserve every persisted lucky egg slot.
--   2. Reserve every persisted animal slot.
--   3. Hand the records to the services so they can spawn
--      the visible models (which then pathfind / place into
--      the slot).
--
-- Phase 2: there is no longer a separate lucky/animal
-- slot pool, but the persisted records still split into
-- Eggs and Animals — each kind restores from its
-- own list, and every record now carries an explicit `Type`
-- stamp, so no reader infers kind from field shapes.
--
-- Phase 2.5.1: restore is LOUD. Every record is either
-- spawned, or named in a Debug.Warn that says exactly why it
-- was not (slot occupied / no free slot to re-home to /
-- reserve race). The pre-2.5.1 restore silently skipped
-- records whose slot was occupied — which is how a phantom
-- record's slot could hide a real Animal from its owner
-- with no trace in the logs. A record whose SlotId no longer
-- resolves (base layout change) is RE-HOMED to a free slot
-- rather than skipped: the object is preserved and its
-- persisted SlotId is re-pointed to where it actually
-- respawned. Nothing is ever auto-destroyed here.
function BaseService.RestorePlayerBase(userId: number, profileData: any)
	Debug.Log('BS', '> RestorePlayerBase', { userId = tostring(userId) })
	Validation.PositiveInteger(userId)
	Validation.AnyTable(profileData)
	local base = bases[basesByOwner[userId]]
	if not base then
		Debug.Warn('BS', 'RestorePlayerBase: no base for user')
		return
	end

	local eggRecords = profileData.LuckyBlocks or {}
	local animalRecords = profileData.Brainrots or {}
	-- Phase 2.5.1 §20: one inventory line at restore. Paired
	-- with the leave-side log in CleanupPlayer, this answers
	-- "was the object saved incorrectly, or loaded incorrectly?"
	-- from two log lines instead of guesswork.
	Debug.Log('BS', 'RestorePlayerBase: persisted inventory', {
		userId = tostring(userId),
		eggs = tostring(#eggRecords),
		animals = tostring(#animalRecords),
	})

	-- One restore pass per kind. Per record:
	--   * slot resolves + Empty      -> Reserve + spawn (normal path)
	--   * slot resolves + occupied   -> SKIP, keep record, loud warn
	--     (never auto-destroy; the load audit already quarantined
	--     true duplicates, so an occupied slot here is a genuine
	--     cross-check hit, and the record stays canonical)
	--   * slot missing/unresolvable  -> re-home to a free slot
	--     (object preserved; persisted SlotId re-pointed to where
	--     it actually respawned)
	--   * ReserveSlot race           -> SKIP, keep record, loud warn
	local function _restore(records: { any }, kind: string, spawn: (number, any, any) -> any)
		for _, record in ipairs(records) do
			if type(record) ~= 'table' then
				continue
			end
			local slot = (type(record.SlotId) == 'string') and BaseService._findSlotById(record.SlotId) or nil
			-- Eggs can NEVER occupy arena stands (hard content
			-- restriction). A persisted Egg pointing at an
			-- arena slot is corrupt/legacy data: fail closed
			-- and re-home it to a normal slot through the
			-- standard missing-slot path below. Never convert
			-- it, never restore it into Arena.
			if slot ~= nil and (slot :: any).arena == true and kind == 'Egg' then
				warn(
					('[ArenaSlots] rejected persisted Egg in Arena slot; re-homing user=%s id=%s slotId=%s'):format(
						tostring(userId),
						tostring(record.Id),
						tostring(record.SlotId)
					)
				)
				slot = nil
			end
			if slot then
				if slot.state ~= SlotType.State.Empty then
					Debug.Warn('BS', ('RestorePlayerBase: %s skipped — slot occupied, record kept'):format(kind), {
						userId = tostring(userId),
						id = tostring(record.Id),
						slotId = tostring(record.SlotId),
						occupantId = tostring(slot.occupantId),
						occupantKind = tostring(slot.occupantKind),
					})
					continue
				end
			else
				local newSlot = BaseService.GetFreeSlot(userId)
				if not newSlot then
					Debug.Warn(
						'BS',
						('RestorePlayerBase: %s kept but unplaceable — no free slot to re-home to'):format(kind),
						{
							userId = tostring(userId),
							id = tostring(record.Id),
							slotId = tostring(record.SlotId),
						}
					)
					continue
				end
				Debug.Warn('BS', ('RestorePlayerBase: %s re-homed to a free slot'):format(kind), {
					userId = tostring(userId),
					id = tostring(record.Id),
					oldSlotId = tostring(record.SlotId),
					newSlotId = newSlot.id,
				})
				-- Stamp the record's SlotId before spawning: the
				-- record IS the profile's table, so this is the
				-- persisted mutation (same write PlayerService
				-- SetXSlot performs through the same reference).
				record.SlotId = newSlot.id
				slot = newSlot
			end
			if BaseService.ReserveSlot(slot.id) then
				spawn(userId, record, slot)
			else
				Debug.Warn(
					'BS',
					('RestorePlayerBase: %s skipped — ReserveSlot lost a race, record kept'):format(kind),
					{
						userId = tostring(userId),
						id = tostring(record.Id),
						slotId = tostring(slot.id),
					}
				)
			end
		end
	end

	-- Lucky eggs first (ordering preserved: their flight/
	-- landing bookkeeping is the more constrained kind),
	-- animals second.
	_restore(eggRecords, 'Egg', function(uid, rec, sl)
		if eggServiceRef then
			eggServiceRef.SpawnFromPersistence(uid, rec, sl)
		end
	end)
	_restore(animalRecords, 'Animal', function(uid, rec, sl)
		if animalServiceRef then
			animalServiceRef.SpawnFromPersistence(uid, rec, sl)
		end
	end)
	Debug.Log('BS', '< RestorePlayerBase done')
end

-- Explicit admin-only wipe. Destroys the runtime on the
-- player's base and clears the persisted lists in PlayerData
-- so a rejoin starts fresh. The full reset (Money back to
-- EconomyConfig.StartingMoney, BaseId cleared, Loaded flipped to
-- false) lives in PlayerService.WipeUser; this function
-- chains the runtime cleanup, then delegates the profile
-- reset to PlayerService so the two are kept in lockstep.
function BaseService.WipePlayerData(userId: number)
	Debug.Log('BS', '> WipePlayerData', { userId = tostring(userId) })
	Validation.PositiveInteger(userId)
	local bid = basesByOwner[userId]
	if not bid then
		-- No base assigned; just reset the profile so a
		-- subsequent rejoin starts from defaults.
		if playerServiceRef then
			playerServiceRef.WipeUser(userId)
		end
		return
	end
	-- Tell the services to drop their runtime instances. They
	-- will also call back into PlayerService to remove the
	-- records from the persisted lists.
	if eggServiceRef then
		eggServiceRef.ForceReleaseBase(bid)
	end
	if animalServiceRef then
		animalServiceRef.ForceReleaseBase(bid)
	end
	-- Reset the slot table (full shared teardown: prompt
	-- sweep, prompt-registry purge, display repaint) so the
	-- admin wipe leaves the same clean-empty base as any other
	-- release path. Ownership is cleared FIRST so the sweep
	-- and validation observe the unassigned state.
	basesByOwner[userId] = nil
	local base = bases[bid]
	if base then
		base.ownerUserId = nil
		base.state = BaseType.State.Available
		-- MAIN GAME: a wipe must not leave a stale lock behind.
		if baseLockServiceRef then
			pcall(function()
				baseLockServiceRef.HandleBaseReleased(bid)
			end)
		end
		PlayerBoard.Clear(base.folder)
		if base.dynamicSlots then
			DynamicSlotService.DestroyBaseSlots(base, base.session)
		end
		DynamicSlotService.DestroyArenaStands(base, base.session)
		_resetSlotsAndSweep(base, 'wipe')
		base._occupiedCount = 0
		if slotServiceRef then
			slotServiceRef.ClearBaseOwner(userId)
			slotServiceRef.UnregisterBase(bid)
		end
		_bumpSession(base)
		BaseService.ValidateBaseRuntime(bid)
	end
	-- Full profile reset (Cash, BaseId, lists, Loaded) goes
	-- through PlayerService.WipeUser.
	if playerServiceRef then
		playerServiceRef.WipeUser(userId)
	end
	Debug.Log('BS', '< WipePlayerData done')
end

-- Build a wire-snapshot of a player's base for the PlayerState push.
-- Phase 2: single `slots` array; each entry now includes
-- `OccupantKind` so the HUD can branch on the occupant type.
--
-- Phase 3: the per-slot array is built by SlotService so the
-- wire shape is owned in one place. The base-level fields
-- (slots + _occupiedCount) are assembled here.
function BaseService.Snapshot(userId: number): { slots: any, _occupiedCount: number }?
	local base = bases[basesByOwner[userId]]
	if not base then
		return nil
	end
	local slots: { [number]: any }?
	if slotServiceRef then
		slots = slotServiceRef.SnapshotBaseSlots(base)
	else
		-- Defensive fallback so a misconfigured bootstrap
		-- still returns a snapshot (the slot data lives
		-- on `base.slots` either way). Mirrors the
		-- authoritative shape including the arena tail.
		slots = {}
		for i = 1, Bases.Slots.Count do
			local s = base.slots[i]
			local pos = s.part and s.part.Position or nil
			slots[i] = {
				Index = i,
				Id = s.id,
				State = s.state,
				OccupantId = s.occupantId,
				OccupantKind = s.occupantKind,
				Position = pos,
			}
		end
		if type(base.arenaSlots) == 'table' then
			for _, s in pairs(base.arenaSlots) do
				if type(s) == 'table' then
					slots[#slots + 1] = {
						Index = s.index,
						Id = s.id,
						State = s.state,
						OccupantId = s.occupantId,
						OccupantKind = s.occupantKind,
						Position = nil,
						Arena = true,
					}
				end
			end
		end
	end
	return {
		slots = slots,
		_occupiedCount = base._occupiedCount,
	}
end

function BaseService.CleanupPlayer(userId: number)
	-- Phase 1: leaving the server is NOT destructive. The
	-- player's animals and lucky eggs are persisted in
	-- PlayerService; on rejoin, RestorePlayerBase re-spawns
	-- them. We just drop the in-memory base so another
	-- player can join and take it; the persisted data is
	-- untouched.
	Debug.Log('BS', '> CleanupPlayer (non-destructive)', { userId = tostring(userId) })
	Validation.PositiveInteger(userId)
	local bid = basesByOwner[userId]
	if not bid then
		return
	end
	-- Phase 2.5.1 §20: the leave-side inventory line. The
	-- profile is still loaded at this point (bootstrap runs
	-- PlayerService cleanup last), so this records exactly what
	-- the player is leaving behind — the counterpart to
	-- RestorePlayerBase's load-side inventory line.
	if playerServiceRef then
		local data = playerServiceRef.GetPlayerData(userId)
		if data then
			Debug.Log('BS', 'CleanupPlayer: persisted inventory at leave', {
				userId = tostring(userId),
				eggs = tostring(data.LuckyBlocks and #data.LuckyBlocks or 0),
				animals = tostring(data.Brainrots and #data.Brainrots or 0),
			})
		end
	end
	-- The runtime instances in Workspace are also dropped on
	-- leave (they're server-side). Their persistent records
	-- remain.
	if eggServiceRef then
		eggServiceRef.CleanupPlayer(userId)
	end
	if animalServiceRef then
		animalServiceRef.CleanupPlayer(userId)
	end
	-- Detach the in-memory base so the slot is reclaimable.
	basesByOwner[userId] = nil
	local base = bases[bid]
	if not base then
		return
	end
	-- MAIN GAME: a leaving owner must never leave their base
	-- permanently locked. Unlock first (visuals + collision +
	-- timer), then proceed with the normal teardown.
	if baseLockServiceRef then
		pcall(function()
			baseLockServiceRef.HandleBaseReleased(bid)
		end)
	end
	-- MAIN GAME: reset the Studio PlayerBoard so the leaving
	-- player's name/avatar cannot linger for the next owner.
	PlayerBoard.Clear(base.folder)
	-- MAIN GAME: same for the multiplier label — the leaving
	-- owner's value must not linger either. Ownership is
	-- still intact here, so the owner-gated hide resolves.
	local okRebHide2, rebHideSvc2 = pcall(require, script.Parent.Rebirth.RebirthService)
	if okRebHide2 and rebHideSvc2 and rebHideSvc2.HideBaseMultiplier then
		pcall(rebHideSvc2.HideBaseMultiplier, userId)
	end
	-- Shared teardown: slot reset (+ stuck-mutex clear),
	-- slot-part prompt sweep, prompt-registry purge, display
	-- repaint. Runs BEFORE ownership is cleared so the repaint
	-- still resolves slots through SlotService.
	--
	-- CONTRACT (slot id re-stamp): any service that captured
	-- `slot.id` by reference (rather than reading it as a
	-- string at the time of reservation) will see this
	-- re-stamp and end up with a stale userId=0 id. Services
	-- that hold an in-flight operation on a slot MUST capture
	-- the id as a string (e.g. on the record) and check the
	-- slot's current state before any post-flight call to
	-- OccupySlot / ReserveSlot / ReleaseSlot.
	-- Dynamic mode: destroy the runtime Slot<k> clones FIRST
	-- (StandPos markers and shell untouched); the sweep below
	-- then observes an already-empty slot table.
	if base.dynamicSlots then
		DynamicSlotService.DestroyBaseSlots(base, base.session)
	end
	DynamicSlotService.DestroyArenaStands(base, base.session)
	_resetSlotsAndSweep(base, 'cleanup')
	if slotServiceRef then
		slotServiceRef.ClearBaseOwner(userId)
		slotServiceRef.UnregisterBase(bid)
	end
	base._occupiedCount = 0
	base.ownerUserId = nil
	base.state = BaseType.State.Available
	_bumpSession(base)
	BaseService.ValidateBaseRuntime(bid)
	Debug.Log('BS', '< CleanupPlayer done', { baseId = bid })
end

return table.freeze(BaseService)
