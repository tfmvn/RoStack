--!strict
--!native
--[[
	DynamicSlotService
	==================
	Runtime Slot lifecycle for the StandPos architecture.

	Studio shapes (Studio is the source of truth):
	  ServerStorage.Assets.Map.Bases.Base.StandTemplate   (ONE template)
	  Workspace.Map.Bases.Base_<n>
	  ├── AnimalStands                            (runtime parent)
	  └── StandPos/StandPos<k>                    (static markers)

	Template -> marker -> runtime:
	  StandPos<k> gives index k AND the exact world CFrame.
	  The template is cloned, renamed `Slot<k>` (the Explorer
	  hierarchy the game presents: Base/AnimalStands/Slot<k>),
	  pivoted EXACTLY onto the marker (no offsets), and
	  parented under the base's AnimalStands.

	Why `Slot<k>` and not `Stand<k>`: the runtime hierarchy
	contract is Base/AnimalStands/Slot1..8. The stable
	persistence identity is the SlotId string
	(`p7:<userId>:slot:<index>`), never the Instance name;
	StandResolver.ParseSlotIndex (AnimalStands scope only)
	distinguishes runtime clones from legacy `Slots/` parts.

  Positioning: PlaceAtCFrame positions a runtime slot onto a
  generated Base-local layout CFrame (StandLayout ring/row
  through Base.Center). PlaceAtStandPos (exact marker transform)
  is kept for compatibility. StandPos markers must still exist
  (legacy gate) but no longer anchor positions or ground.

  Slot count boundary (rebirth unlocks): GetDesiredSlotCount is
  the single function that decides how many slots a base
  gets: min(markers present, Bases.Slots.Count global max,
  RebirthConfig unlock for the owner's rebirth). Callers use
  ReconcileBaseSlots — no other rewrite needed.

	Session fencing: Build/Destroy/Reconcile take the base's
	live session and refuse stale ones with a [DynamicSlots]
	warn. BaseService bumps `base.session` on every
	assign/release.

	Event-driven only: creation/destruction happens on assign,
	release, explicit reconcile, or controlled rebuild. No
	Heartbeat, no polling, no Workspace scans (markers are
	resolved from the base folder directly).

	What this service does NOT own: persistence, cash,
	stealing, upgrades, animals — those keep reading the slot
	records this service builds.

  ARENA STANDS (separate track, same patterns):
  `ServerStorage.Assets.Map.Bases.Base.ArenaStandTemplate`
  cloned per `ArenaStandPos<k>` marker into
  `Base/ArenaAnimalStands` as `ArenaStand<k>`. Arena clones
  carry REAL slot records (`base.arenaSlots`, `arena = true`,
  index namespace `ARENA_INDEX_BASE + k`, SlotId
  `p7:<userId>:slot:<index>`) registered with SlotService, so
  the canonical grab/place pipeline works unchanged — but the
  records live OUTSIDE `base.slots`, so income, capacity,
  HUD snapshots, egg placement, and steal delivery (all
  `base.slots` readers) never see them. Session fencing,
  trace warns ([DynamicArenaStands]/[ArenaSlots] prefix), and
  event-driven lifecycle mirror the Slot track; the Slot
  track itself is untouched by arena work.
]]

local ServerStorage = game:GetService('ServerStorage')
local ReplicatedStorage = game:GetService('ReplicatedStorage')

local Bases = require(ReplicatedStorage.Config.World.Bases)
local StandConfig = require(ReplicatedStorage.Config.World.Bases).Stands
local StandLayoutConfig = require(ReplicatedStorage.Config.World.Bases).Layout
local RebirthConfig = require(ReplicatedStorage.Config.Economy.Rebirth)
local SlotType = require(ReplicatedStorage.Types.SlotType)
local StandResolver = require(ReplicatedStorage.Utility.StandResolver)
local StandLayout = require(ReplicatedStorage.Utility.StandLayout)
local Debug = require(ReplicatedStorage.Utility.Debug)

local DynamicSlotService = {}

-- Rebirth unlock resolver (injected by bootstrap to avoid a
-- require cycle: RebirthService reads BaseService, which owns
-- this module). Signature: (userId: number) -> rebirth number.
-- Unset (specs/headless) = legacy behavior: marker/Bases
-- counts only, no unlock cap.
local unlockResolver: ((number) -> number)? = nil

function DynamicSlotService.SetUnlockResolver(fn: ((number) -> number)?)
	if fn ~= nil and type(fn) ~= 'function' then
		return
	end
	unlockResolver = fn
end

-- Unlock counts for a player: { Animal: number, Arena: number }.
-- Falls back to unbounded when no resolver is wired (legacy).
local function resolveUnlocked(userId: number?): { Animal: number, Arena: number }?
	if unlockResolver == nil or type(userId) ~= 'number' then
		return nil
	end
	local rebirth: number? = nil
	pcall(function()
		rebirth = (unlockResolver :: (number) -> number)(userId :: number)
	end)
	if type(rebirth) ~= 'number' or (rebirth :: number) < 0 then
		return nil
	end
	local counts = RebirthConfig.StandsFor(rebirth :: number)
	return { Animal = counts.Animal, Arena = counts.Arena }
end

-- Base-local frame for generated layouts: the base folder pivot.
-- All layout math is computed in this frame so rotated bases
-- rotate their whole stand layout with them.
local function baseFrame(baseFolder: Instance?): CFrame?
	if typeof(baseFolder) ~= 'Instance' then
		return nil
	end
	local cf: CFrame? = nil
	pcall(function()
		cf = (baseFolder :: Instance):GetPivot()
	end)
	if typeof(cf) ~= 'CFrame' then
		return nil
	end
	return cf
end

-- Stand front axis, measured from the template (never assumed):
-- the project convention is Stand.Button.Base (fallback
-- Button.PressPart — the same parts animals face). Returns the
-- button offset in TEMPLATE-LOCAL XZ (unit), or nil when the
-- template carries no resolvable button (caller keeps the legacy
-- lookAt orientation). Translation-invariant: works for any
-- template pivot or base transform.
local function measureFrontOffset(template: Instance?): Vector3?
	local pivot: CFrame? = nil
	pcall(function()
		if typeof(template) ~= 'Instance' then
			return
		end
		if (template :: Instance):IsA('BasePart') then
			pivot = ((template :: Instance) :: BasePart).CFrame
		elseif (template :: Instance):IsA('Model') then
			pivot = ((template :: Instance) :: Model):GetPivot()
		end
	end)
	if typeof(pivot) ~= 'CFrame' then
		return nil
	end
	local target: BasePart? = nil
	pcall(function()
		target = StandResolver.GetStandFacingTarget(template)
	end)
	if target == nil then
		return nil
	end
	local rel: Vector3? = nil
	pcall(function()
		local targetCF = CFrame.new((target :: BasePart).Position)
		rel = ((pivot :: CFrame):ToObjectSpace(targetCF)).Position
	end)
	if type(rel) ~= 'Vector3' then
		return nil
	end
	local flat = Vector3.new((rel :: Vector3).X, 0, (rel :: Vector3).Z)
	if flat.Magnitude < 1e-3 then
		return nil
	end
	return flat.Unit
end

-- Yaw-only stand orientation: rotate the WHOLE stand so its
-- measured front axis points at `centerPos` horizontally.
-- Returns nil when no facing can be derived (caller keeps its
-- fallback rotation). Never tilts; never touches Y.
local function orientTowardCenter(worldPos: Vector3, centerPos: Vector3, frontOffset: Vector3?): CFrame?
	if frontOffset ~= nil then
		local dx = centerPos.X - worldPos.X
		local dz = centerPos.Z - worldPos.Z
		if dx * dx + dz * dz >= 1e-6 then
			local theta = math.atan2(dx, dz) - math.atan2(frontOffset.X, frontOffset.Z)
			return CFrame.new(worldPos) * CFrame.Angles(0, theta, 0)
		end
	end
	return nil
end
-- part inside each live Base (transparent 1x1x1, anchored,
-- non-colliding, placed at the real ground/layout center and
-- oriented to the Base's intended forward). The animal ring AND
-- the arena row generate relative to Center.CFrame; ground Y is
-- Center.Position.Y. Falls back to the base pivot (legacy) with
-- a loud warn when Center is missing or unusable.
local function layoutCenter(baseFolder: Instance?): CFrame?
	if typeof(baseFolder) ~= 'Instance' then
		return nil
	end
	local center: Instance? = nil
	pcall(function()
		center = (baseFolder :: Instance):FindFirstChild('Center')
	end)
	if center ~= nil and (center :: Instance):IsA('BasePart') then
		local cf: CFrame? = nil
		pcall(function()
			cf = ((center :: Instance) :: BasePart).CFrame
		end)
		if typeof(cf) == 'CFrame' then
			return cf
		end
	end
	Debug.Warn('StandLayout', 'Base has no usable Center part; falling back to base pivot')
	return baseFrame(baseFolder)
end

-- Created runtime clones per base, for exact-scope destruction:
-- [baseId] = { Instance }. StandPos markers and the Base shell
-- are never tracked here and therefore never destroyed.
-- Arena clones live in the SEPARATE createdArenaByBase table so
-- the two tracks can never address each other's instances.
local createdByBase: { [string]: { Instance } } = {}
local createdArenaByBase: { [string]: { Instance } } = {}

-- Cached templates (revalidated on Parent loss), one per track.
local cachedTemplate: Instance? = nil
local cachedArenaTemplate: Instance? = nil

-- Shared session gate: true iff `session` is still the base's
-- live session, else a [tag] warn + false (caller changes
-- nothing). One gate for both tracks — never a second session
-- system.
local function checkSession(base: any, session: number, tag: string, op: string): boolean
	if type(base) ~= 'table' or type(base.id) ~= 'string' then
		return false
	end
	if (base.session or 0) ~= session then
		Debug.Warn('DynamicSlots', ('[%s] Refused stale session callback (%s) base=%s callbackSession=%s currentSession=%s'):format(
				tag,
				op,
				tostring(base.id),
				tostring(session),
				tostring(base.session or 0)
			))
		return false
	end
	return true
end

-- Ensure the runtime container folder exists under a base
-- folder, creating it once with a warn. Returns nil when the
-- base folder itself is unusable.
local function ensureContainer(folder: Instance?, containerName: string, baseId: string, tag: string): Instance?
	if typeof(folder) ~= 'Instance' then
		return nil
	end
	local container = folder:FindFirstChild(containerName)
	if container == nil then
		container = Instance.new('Folder')
		container.Name = containerName
		container.Parent = folder
		Debug.Warn('DynamicSlots', ('[%s] Base=%s had no %s folder; created it'):format(tag, tostring(baseId), containerName))
	end
	return container
end

-- --- Template ---------------------------------------------------------

local function templatePath(): string
	return 'ServerStorage.Assets.Map.Bases.Base.StandTemplate'
end

-- Resolve the ONE reusable stand template. Never clones, never
-- creates. Warns actionably on any problem; returns nil when
-- unusable (callers fail closed for that base).
function DynamicSlotService.GetTemplate(): Instance?
	if cachedTemplate ~= nil and (cachedTemplate :: Instance).Parent ~= nil then
		return cachedTemplate
	end
	cachedTemplate = nil
	local assets = ServerStorage:FindFirstChild('Assets')
	local map = assets and assets:FindFirstChild('Map') or nil
	local bases = map and map:FindFirstChild('Bases') or nil
	local base = bases and bases:FindFirstChild('Base') or nil
	local template = base and base:FindFirstChild('StandTemplate') or nil
	if template == nil then
		warn(('[DynamicSlots] Missing stand template at %s'):format(templatePath()))
		return nil
	end
	if not template:IsA('Model') and not template:IsA('BasePart') then
		Debug.Warn('DynamicSlots', ('Stand template at %s must be a Model (or BasePart), got %s'):format(
			templatePath(),
			template.ClassName
		))
		return nil
	end
	-- Structural check against what consumers resolve:
	-- Stand.Slot.* (placement + distance math need a physical
	-- root) and Stand.Button.PressPart (cash). The upgrade
	-- button is deliberately NOT expected inside the stand
	-- template: the canonical source is the sibling UI catalog
	-- Base.Ui.Stand.UpgradeButtonTemplate, cloned per runtime
	-- slot by StandDisplayService — runtime MenuGuis start
	-- empty by design.
	local missing: { string } = {}
	local probe = StandResolver.GetStandParts(template)
	if probe.root == nil then
		missing[#missing + 1] = 'Slot/Root (placement + distance math need a physical root)'
	end
	if probe.pressPart == nil then
		missing[#missing + 1] = 'Button/PressPart (cash collection will have no trigger)'
	end
	-- The canonical upgrade UI source (NOT inside the stand
	-- template): Base.Ui.Stand.UpgradeButtonTemplate.
	-- Validated here (not just at clone time) so a missing or
	-- mistyped catalog entry fails loudly at boot instead of
	-- leaving every runtime slot buttonless.
	do
		local baseNode = base
		local ui = baseNode and baseNode:FindFirstChild('Ui') or nil
		local standUi = ui and ui:FindFirstChild('Stand') or nil
		local upgradeTpl = standUi and standUi:FindFirstChild('UpgradeButtonTemplate') or nil
		if upgradeTpl == nil then
			missing[#missing + 1] = 'Base.Ui.Stand.UpgradeButtonTemplate (upgrade UI will not bind on any runtime slot)'
		elseif not upgradeTpl:IsA('TextButton') then
			missing[#missing + 1] = 'Base.Ui.Stand.UpgradeButtonTemplate must be a TextButton (got '
				.. upgradeTpl.ClassName
				.. ')'
		end
	end
	if #missing > 0 then
		warn(('[DynamicSlots] Stand template at %s is missing: %s'):format(templatePath(), table.concat(missing, '; ')))
		-- Census the template's actual children so the Studio
		-- hierarchy gap is visible in the log (names, not
		-- assumptions): a renamed/moved part shows up here.
		pcall(function()
			local names: { string } = {}
			for _, child in ipairs((template :: Instance):GetChildren()) do
				names[#names + 1] = child.Name .. ':' .. child.ClassName
			end
			Debug.Warn('DynamicSlots', table.concat(names, ', '))
		end)
	end
	cachedTemplate = template
	return cachedTemplate
end

-- --- StandPos markers ---------------------------------------------------

-- Sorted marker nodes for a base folder (empty when the base
-- has no StandPos setup — caller falls back to legacy).
function DynamicSlotService.GetStandPositions(baseFolder: Instance?): { Instance }
	return StandResolver.GetStandPosSorted(baseFolder)
end

-- --- Slot count boundary (rebirth unlocks) ------------------------

-- How many runtime slots this base should have RIGHT NOW.
-- min(physical markers present, Bases.Slots.Count global max,
-- rebirth-unlocked count). Markers must still exist (they anchor
-- the ground plane); their COUNT no longer caps — generated
-- layout positions replace marker positions.
function DynamicSlotService.GetDesiredSlotCount(baseFolder: Instance?, _userId: number?): number
	local markers = DynamicSlotService.GetStandPositions(baseFolder)
	if #markers == 0 then
		return 0
	end
	local unlocked = resolveUnlocked(_userId)
	if unlocked ~= nil then
		-- Generated ring: unlock decides, hard-capped by the
		-- global SlotCount maximum — marker count is not a cap
		-- (markers only anchor the ground plane now).
		return math.min(unlocked.Animal, Bases.Slots.Count)
	end
	return math.min(#markers, Bases.Slots.Count)
end

-- --- Positioning (the ONE place) ------------------------------------------

-- World transform of a StandPos marker, by actual type:
-- BasePart -> CFrame, Attachment -> WorldCFrame, Model/PVInstance
-- -> GetPivot(). Returns nil (with a warn) when the marker has
-- no usable transform — the caller skips that slot LOUDLY
-- instead of parenting an unpositioned clone.
local function markerWorldCFrame(marker: Instance): CFrame?
	if marker:IsA('BasePart') then
		return marker.CFrame
	end
	if marker:IsA('Attachment') then
		return marker.WorldCFrame
	end
	-- Anything else pivotable (Model, etc.).
	local ok, pivot = pcall(function()
		return (marker :: PVInstance):GetPivot()
	end)
	if ok and typeof(pivot) == 'CFrame' then
		return pivot
	end
	Debug.Warn('DynamicSlots', ('StandPos marker %s has no usable transform (type %s); skipping slot'):format(
			marker:GetFullName(),
			marker.ClassName
		))
	return nil
end

-- Pivot a runtime clone onto an explicit world CFrame
-- (generated-layout path). Same guarantees as PlaceAtStandPos;
-- the caller owns where the CFrame came from.
function DynamicSlotService.PlaceAtCFrame(clone: Instance, target: CFrame): boolean
	if typeof(target) ~= 'CFrame' then
		return false
	end
	local ok, err = pcall(function()
		(clone :: Instance):PivotTo(target)
	end)
	if not ok then
		warn(
			('[DynamicSlots] Failed to position %s at generated CFrame: %s'):format(
				(clone :: Instance):GetFullName(),
				tostring(err)
			)
		)
		return false
	end
	return true
end

-- Pivot a runtime clone EXACTLY onto its marker: position AND
-- rotation come from the marker. No offsets. Works for Model
-- and BasePart clones. (Legacy marker path — kept for
-- compatibility; generated layouts use PlaceAtCFrame.)
function DynamicSlotService.PlaceAtStandPos(clone: Instance, marker: Instance): boolean
	local target = markerWorldCFrame(marker)
	if target == nil then
		return false
	end
	local ok, err = pcall(function()
		clone:PivotTo(target)
	end)
	if not ok then
		warn(
			('[DynamicSlots] Failed to position %s at %s: %s'):format(
				clone:GetFullName(),
				marker:GetFullName(),
				tostring(err)
			)
		)
		return false
	end
	return true
end

-- --- Construction ----------------------------------------------------------

-- Arena slot index namespace lives in SlotType (single
-- source of truth with BuildId's range assert); the accessor
-- below re-exports it for arena consumers and tests.
function DynamicSlotService.ArenaSlotIndexBase(): number
	return SlotType.ArenaSlotIndexBase
end

local function buildRecord(baseId: string, userId: number, index: number, stand: Instance): any
	local parts = StandResolver.GetStandParts(stand)
	return {
		id = SlotType.BuildId(userId, SlotType.Kind.Slot, index),
		ownerUserId = userId,
		baseId = baseId,
		kind = SlotType.Kind.Slot,
		index = index,
		state = SlotType.State.Empty,
		occupantId = nil,
		occupantKind = nil,
		_mutex = false,
		part = parts.root,
		cashCollector = parts.pressPart,
		stand = stand,
		standIndex = index,
		offset = Bases.Slots.Offsets[index] or Vector3.new(0, 2, 0),
	}
end

-- Arena slot record: same shape as a normal record plus
-- the `arena` discriminator. `part` resolves through the
-- same StandResolver (Root/Slot fallbacks), so distance
-- checks, settle math, and prompt parenting work unchanged.
-- `cashCollector` resolves the stand's Button.PressPart like
-- a normal slot (nil when the template has no Button —
-- collection is then unavailable exactly as on a
-- button-less normal stand).
-- `standIndex`/`arenaIndex` is the authored <k>; `index` is
-- the namespaced runtime index used in the SlotId.
local function buildArenaRecord(baseId: string, userId: number, arenaIndex: number, stand: Instance): any
	local parts = StandResolver.GetStandParts(stand)
	local index = SlotType.ArenaSlotIndexBase + arenaIndex
	return {
		id = SlotType.BuildId(userId, SlotType.Kind.Slot, index),
		ownerUserId = userId,
		baseId = baseId,
		kind = SlotType.Kind.Slot,
		index = index,
		arenaIndex = arenaIndex,
		arena = true,
		state = SlotType.State.Empty,
		occupantId = nil,
		occupantKind = nil,
		_mutex = false,
		part = parts.root,
		cashCollector = parts.pressPart,
		stand = stand,
		standIndex = arenaIndex,
		offset = Vector3.new(0, 2, 0),
	}
end

-- Rebuild `base.arenaSlots` from the live ArenaStand<k>
-- clones in the container (sorted by <k> — deterministic,
-- never descendant order). Clones are reused across
-- assignments; records are always rebuilt fresh for the
-- current owner. Stands without a resolvable root part get
-- NO record (loud warn): a record without a part would
-- break distance checks and settle math.
local function rebuildArenaRecords(base: any, userId: number): number
	base.arenaSlots = {}
	local folder = base.folder
	if typeof(folder) ~= 'Instance' then
		return 0
	end
	local container = folder:FindFirstChild(StandResolver.Names.ArenaStandsFolder)
	if container == nil then
		return 0
	end
	local stands: { any } = {}
	for _, child in ipairs((container :: Instance):GetChildren()) do
		local k = StandResolver.ParseArenaStandIndex(child.Name)
		if k ~= nil then
			stands[#stands + 1] = { index = k, stand = child }
		end
	end
	table.sort(stands, function(a: any, b: any)
		return a.index < b.index
	end)
	for _, entry in ipairs(stands) do
		local record = buildArenaRecord(base.id, userId, entry.index, entry.stand)
		if record.part == nil then
			Debug.Warn('ArenaSlots', ('Base=%s ArenaStand%d has no resolvable root part; no slot record built'):format(
					tostring(base.id),
					entry.index
				))
		else
			base.arenaSlots[#base.arenaSlots + 1] = record
		end
	end
	return #base.arenaSlots
end

-- (Re)index the live arena clones for the current owner:
-- drop replaced records from SlotService, rebuild from the
-- container children, register fresh. Lazy SlotService
-- require mirrors the IncomeService / CarryPrompts pattern
-- below — no load-time cycle.
local function refreshArenaRecords(base: any, userId: number): number
	pcall(function()
		local SlotService = require(script.Parent.SlotService)
		if SlotService and SlotService.UnregisterArenaSlots then
			SlotService.UnregisterArenaSlots(base.id)
		end
	end)
	local records = rebuildArenaRecords(base, userId)
	pcall(function()
		local SlotService = require(script.Parent.SlotService)
		if SlotService and SlotService.RegisterArenaSlots then
			SlotService.RegisterArenaSlots(base)
		end
	end)
	return records
end

-- Create (or preserve) the runtime slots for an assignment.
-- Returns the number of live slots. Never throws. Session-gated:
-- a stale session aborts with a warn and changes nothing.
function DynamicSlotService.BuildBaseSlots(base: any, userId: number, session: number): number
	if type(base) ~= 'table' or type(base.id) ~= 'string' then
		return 0
	end
	if (base.session or 0) ~= session then
		Debug.Warn('DynamicSlots', ('Refused stale session callback (build) base=%s callbackSession=%s currentSession=%s'):format(
				tostring(base.id),
				tostring(session),
				tostring(base.session or 0)
			))
		return 0
	end
	local folder = base.folder
	if typeof(folder) ~= 'Instance' then
		warn(('[DynamicSlots] Base=%s has no folder; cannot build slots'):format(tostring(base.id)))
		return 0
	end
	local template = DynamicSlotService.GetTemplate()
	if template == nil then
		Debug.Warn('DynamicSlots', ('Base assigned: %s session=%s but the StandTemplate is unusable; ZERO slots built'):format(
				tostring(base.id),
				tostring(session)
			))
		return 0
	end
	local markers = DynamicSlotService.GetStandPositions(folder)
	if #markers == 0 then
		Debug.Warn('DynamicSlots', ('Base assigned: %s session=%s but ZERO StandPos markers found under %s; skipping dynamic build'):format(
				tostring(base.id),
				tostring(session),
				folder:GetFullName()
			))
		return 0
	end
	local standsFolder = folder:FindFirstChild(StandResolver.Names.StandsFolder)
	if standsFolder == nil then
		standsFolder = Instance.new('Folder')
		standsFolder.Name = StandResolver.Names.StandsFolder
		standsFolder.Parent = folder
		Debug.Warn('DynamicSlots', ('Base=%s had no AnimalStands folder; created it'):format(tostring(base.id)))
	end
	Debug.Warn('DynamicSlots', ('Base assigned: %s session=%s AnimalStands=%s template=%s'):format(
			tostring(base.id),
			tostring(session),
			(standsFolder :: Instance):GetFullName(),
			(template :: Instance):GetFullName()
		))
	local desired = DynamicSlotService.GetDesiredSlotCount(folder, userId)
	if desired <= 0 then
		warn(
			('[DynamicSlots] Invalid desired slot count (%d) for Base=%s; building nothing'):format(
				desired,
				tostring(base.id)
			)
		)
		return 0
	end
	Debug.Warn('DynamicSlots', ('Desired slot count for Base=%s: %d (%d markers)'):format(tostring(base.id), desired, #markers))
	local created = createdByBase[base.id]
	if not created then
		created = {}
		createdByBase[base.id] = created
	end
	-- Generated layout: base-local ring from StandLayoutConfig,
	-- transformed through the Center part's CFrame (rotated bases
	-- rotate their layout). Ground plane = Center.Position.Y.
	local baseCF = layoutCenter(folder)
	if baseCF == nil then
		Debug.Warn('DynamicSlots', ('Base=%s has no usable layout origin; building nothing'):format(tostring(base.id)))
		return 0
	end
	local groundY = (baseCF :: CFrame).Y
	local animalCfg = StandLayoutConfig.Animal
	-- Circle center = Center + local forward offset (whole ring
	-- shifts as one unit; facing targets the shifted center).
	-- Local Y is ALWAYS 0 here: Center.CFrame supplies the exact
	-- ground Y (Center.Position.Y) exactly once. Putting groundY
	-- into the local frame would add it twice (sky-high stands).
	-- ANIMAL TRACK ONLY (ring layout — never a straight row):
	-- circle center = Center + forward offset; stands face the
	-- shifted circle center. The arena track below uses its own
	-- separate row calculation; the two must never share it.
	local circleX, circleZ = 0, animalCfg.ForwardOffset
	local locals = StandLayout.AnimalLocals(
		desired,
		animalCfg.RadiusX,
		animalCfg.RadiusZ,
		animalCfg.RightStartAngle,
		animalCfg.RightEndAngle,
		circleX,
		circleZ
	)
		Debug.Warn('StandLayout', ('Base=%s slots=%d groundY=%.2f'):format(
			tostring(base.id),
			desired,
			(groundY :: number)
		))
	-- Measured front axis for THIS template (Button side). One
	-- measurement per build; every stand below orients from it.
	local frontOffset = measureFrontOffset(template)
	if frontOffset ~= nil then
				Debug.Warn('StandLayout', ('Base=%s stand front offset=(%.2f, %.2f)'):format(
				tostring(base.id),
				frontOffset.X,
				frontOffset.Z
			))
	else
				Debug.Warn('StandLayout', ('Base=%s no button resolvable; keeping lookAt orientation'):format(tostring(base.id)))
	end
	local centerPos = (baseCF :: CFrame).Position
	local slots: { [number]: any } = {}
	local live = 0
	for index = 1, desired do
		local slotName = 'Slot' .. tostring(index)
		-- World position from the ring (Center Y exact) + yaw so
		-- the measured front points at Center. Whole stand moves
		-- and rotates as one assembly; animals ride as children.
		local standCF: CFrame? = nil
		do
			local localCF = locals[index]
			if localCF ~= nil then
				local worldPos = (baseCF :: CFrame) * Vector3.new(localCF.X, 0, localCF.Z)
				standCF = orientTowardCenter(worldPos, centerPos, frontOffset)
				if standCF == nil then
					standCF = (baseCF :: CFrame) * CFrame.new(localCF.X, 0, localCF.Z)
						* (localCF - localCF.Position)
				end
			end
		end
		local existing: Instance? = nil
		for _, inst in ipairs(created) do
			if inst.Parent ~= nil and inst.Name == slotName then
				existing = inst
				break
			end
		end
		if existing == nil then
			local stale = (standsFolder :: Instance):FindFirstChild(slotName)
			if stale ~= nil and StandResolver.ParseSlotIndex(stale.Name) ~= nil then
				existing = stale
				created[#created + 1] = stale
								Debug.Warn('DynamicSlots', ('Reusing pre-existing %s for Base=%s session=%s'):format(
						slotName,
						tostring(base.id),
						tostring(session)
					))
			end
		end
		if existing == nil then
						Debug.Warn('DynamicSlots', ('Cloning StandTemplate for SlotId %d (Base=%s)'):format(
					index,
					tostring(base.id)
				))
			local ok, clone = pcall(function()
				return (template :: Instance):Clone()
			end)
			if not ok or clone == nil then
				warn(
					('[DynamicSlots] Failed to clone StandTemplate for Base=%s slot=%d'):format(
						tostring(base.id),
						index
					)
				)
			else
				local cloneInst = clone :: Instance
				cloneInst.Name = slotName
				cloneInst.Parent = standsFolder
				-- Generated world transform (position + measured
				-- front orientation), computed above.
				local placed = false
				if standCF ~= nil then
					placed = DynamicSlotService.PlaceAtCFrame(clone, standCF :: CFrame)
										Debug.Warn('StandLayout', ('Base=%s Animal Slot=%d Position=%.1f, %.1f, %.1f'):format(
							tostring(base.id),
							index,
							(standCF :: CFrame).X,
							(standCF :: CFrame).Y,
							(standCF :: CFrame).Z
						))
				end
				if placed then
					created[#created + 1] = clone
					existing = clone
					Debug.Log('DS', 'DynamicSlots created', {
						base = tostring(base.id),
						slot = tostring(index),
						session = tostring(session),
					})
										Debug.Warn('DynamicSlots', ('Parenting %s -> %s'):format(slotName, (standsFolder :: Instance):GetFullName()))
				else
					pcall(function()
						(clone :: Instance):Destroy()
					end)
				end
			end
		end
		if existing ~= nil then
			-- Generated layout is authoritative every build:
			-- reused stands are moved AND re-oriented to their
			-- current ring slot (animals ride along as stand
			-- children — no detach, no second animal position).
			if standCF ~= nil then
				DynamicSlotService.PlaceAtCFrame(existing, standCF :: CFrame)
			end
			slots[index] = buildRecord(base.id, userId, index, existing)
			live += 1
		end
	end
	base.slots = slots
	base.dynamicSlots = true
	return live
end

-- Destroy this base's runtime clones and empty its slot table.
-- StandPos markers, the Base shell, and the template are never
-- touched. Session-gated like Build. Never throws.
function DynamicSlotService.DestroyBaseSlots(base: any, session: number): number
	if type(base) ~= 'table' or type(base.id) ~= 'string' then
		return 0
	end
	if (base.session or 0) ~= session then
				Debug.Warn('DynamicSlots', ('Refused stale session callback (destroy) base=%s callbackSession=%s currentSession=%s'):format(
				tostring(base.id),
				tostring(session),
				tostring(base.session or 0)
			))
		return 0
	end
	local destroyed = 0
	-- Detach cash triggers while the records still exist (the
	-- part-keyed IncomeService maps must not pin destroyed
	-- parts or stale slot records across reassignments), then
	-- purge prompt-registry entries while ids are still known.
	local okCash, cashErr = pcall(function()
		local IncomeService = require(script.Parent.Parent.IncomeService)
		if IncomeService and IncomeService.ForgetCollectorsForSlots then
			IncomeService.ForgetCollectorsForSlots(base.slots)
		end
	end)
	if not okCash then
		warn(('[DynamicSlots] Collector detach failed for Base=%s: %s'):format(tostring(base.id), tostring(cashErr)))
	end
	-- Purge prompt-registry entries while the slot records
	-- (and their ids) still exist — after this the table is
	-- empty and the ids are unrecoverable.
	local okPrompt, promptErr = pcall(function()
		local CarryPrompts = require(script.Parent.Parent.Animal.CarryPrompts)
		if CarryPrompts and CarryPrompts.ForgetSlotsForBase then
			CarryPrompts.ForgetSlotsForBase({ slots = base.slots })
		end
	end)
	if not okPrompt then
		warn(
			('[DynamicSlots] Prompt-registry purge failed for Base=%s: %s'):format(
				tostring(base.id),
				tostring(promptErr)
			)
		)
	end
	local created = createdByBase[base.id]
	if created then
		for _, inst in ipairs(created) do
			pcall(function()
				(inst :: Instance):Destroy()
			end)
			destroyed += 1
		end
		createdByBase[base.id] = nil
	end
	-- Belt-and-braces: any Slot<k> clone still parented under
	-- AnimalStands (e.g. created before a server restart of
	-- this table) is destroyed too. StandPos markers live in
	-- the SEPARATE StandPos folder and are never matched here.
	local ok, folderErr = pcall(function()
		local folder = base.folder
		if typeof(folder) ~= 'Instance' then
			return
		end
		local standsFolder = folder:FindFirstChild(StandResolver.Names.StandsFolder)
		if standsFolder == nil then
			return
		end
		for _, child in ipairs((standsFolder :: Instance):GetChildren()) do
			if StandResolver.ParseSlotIndex(child.Name) ~= nil then
				local already = false
				if created then
					for _, inst in ipairs(created) do
						if inst == child then
							already = true
							break
						end
					end
				end
				if not already then
					child:Destroy()
					destroyed += 1
				end
			end
		end
	end)
	if not ok then
		warn(('[DynamicSlots] Stand sweep failed for Base=%s: %s'):format(tostring(base.id), tostring(folderErr)))
	end
	base.slots = {}
	if destroyed > 0 then
				Debug.Warn('DynamicSlots', ('Destroyed %d runtime slots for Base=%s session=%s'):format(
				destroyed,
				tostring(base.id),
				tostring(session)
			))
	end
	return destroyed
end

-- Canonical reconcile: desired count -> create missing, remove
-- extra, preserve the rest in place (no rebuild when the count
-- is unchanged). Occupied slots are NEVER destroyed: removal
-- of an occupied slot is refused with a warn (no data loss
-- until a real migration policy exists). Session-gated.
function DynamicSlotService.ReconcileBaseSlots(base: any, userId: number, session: number): number
	if type(base) ~= 'table' or type(base.id) ~= 'string' then
		return 0
	end
	if (base.session or 0) ~= session then
				Debug.Warn('DynamicSlots', ('Refused stale session callback (reconcile) base=%s callbackSession=%s currentSession=%s'):format(
				tostring(base.id),
				tostring(session),
				tostring(base.session or 0)
			))
		return 0
	end
	local folder = base.folder
	local desired = DynamicSlotService.GetDesiredSlotCount(folder, userId)
	local slots = base.slots
	if type(slots) ~= 'table' then
		slots = {}
		base.slots = slots
	end
	-- Remove extras above the desired count (unoccupied only).
	for index, slot in pairs(slots) do
		if type(index) == 'number' and index > desired then
			if slot.occupantId ~= nil or slot.state ~= SlotType.State.Empty then
								Debug.Warn('DynamicSlots', ('Attempted to remove occupied SlotId %s during slot-count reconciliation; refusing destructive removal.'):format(
						tostring(slot.id)
					))
			else
				local stand = slot.stand
				if typeof(stand) == 'Instance' then
					pcall(function()
						(stand :: Instance):Destroy()
					end)
				end
				local created = createdByBase[base.id]
				if created then
					for i, inst in ipairs(created) do
						if inst == stand then
							table.remove(created, i)
							break
						end
					end
				end
				slots[index] = nil
								Debug.Warn('DynamicSlots', ('Destroyed runtime SlotId %s for Base=%s (locked by progression)'):format(
						tostring(slot.id),
						tostring(base.id)
					))
			end
		end
	end
	-- Count the survivors; build only if something is missing.
	local live = 0
	for index in pairs(slots) do
		if type(index) == 'number' and index <= desired then
			live += 1
		end
	end
	if live == desired then
		return desired
	end
	return DynamicSlotService.BuildBaseSlots(base, userId, session)
end

-- --- Arena stands (separate track) ------------------------------------------
--
-- Same lifecycle patterns as Slots, fully separate scope:
--   template: ServerStorage.Assets.Map.Bases.Base.ArenaStandTemplate
--   markers:  Base/ArenaStandPos/ArenaStandPos<k>
--   runtime:  Base/ArenaAnimalStands/ArenaStand<k>
-- Arena clones are presentation-only: no slot records, no
-- SlotService registration, no cash triggers, no prompts. (A
-- future arena-battle system will consume the live clones via
-- the container folder; it must resolve them live and fence on
-- base.session like everything else.)

local function arenaTemplatePath(): string
	return 'ServerStorage.Assets.Map.Bases.Base.ArenaStandTemplate'
end

-- Resolve the ONE reusable arena template. No structural probe
-- (no consumers resolve children yet — the first arena-battle
-- consumer extends validation here, mirroring GetTemplate).
function DynamicSlotService.GetArenaTemplate(): Instance?
	if cachedArenaTemplate ~= nil and (cachedArenaTemplate :: Instance).Parent ~= nil then
		return cachedArenaTemplate
	end
	cachedArenaTemplate = nil
	local assets = ServerStorage:FindFirstChild('Assets')
	local map = assets and assets:FindFirstChild('Map') or nil
	local bases = map and map:FindFirstChild('Bases') or nil
	local base = bases and bases:FindFirstChild('Base') or nil
	local template = base and base:FindFirstChild('ArenaStandTemplate') or nil
	if template == nil then
		warn(('[DynamicArenaStands] Missing ArenaStandTemplate at %s'):format(arenaTemplatePath()))
		return nil
	end
	if not template:IsA('Model') and not template:IsA('BasePart') then
				Debug.Warn('DynamicArenaStands', ('ArenaStandTemplate at %s must be a Model (or BasePart), got %s'):format(
				arenaTemplatePath(),
				template.ClassName
			))
		return nil
	end
	cachedArenaTemplate = template
	return cachedArenaTemplate
end

function DynamicSlotService.GetArenaStandPositions(baseFolder: Instance?): { Instance }
	return StandResolver.GetArenaStandPosSorted(baseFolder)
end

-- How many runtime arena stands this base should have RIGHT
-- NOW. Rebirth-unlocked count when a resolver is wired (markers
-- must still exist for the ground plane, as on the Slot track);
-- legacy marker count otherwise.
function DynamicSlotService.GetDesiredArenaStandCount(baseFolder: Instance?, _userId: number?): number
	local markers = DynamicSlotService.GetArenaStandPositions(baseFolder)
	if #markers == 0 then
		return 0
	end
	local unlocked = resolveUnlocked(_userId)
	if unlocked ~= nil then
		-- Generated row: unlock decides, hard-capped by the id
		-- namespace (SlotType.MaxArenaStands), not by markers.
		return math.min(unlocked.Arena, SlotType.MaxArenaStands)
	end
	return #markers
end

local function mkArenaPart(name: string, size: Vector3, color: BrickColor): Part
	local part = Instance.new('Part')
	part.Name = name
	part.Size = size
	part.Anchored = true
	part.CanCollide = false
	part.BrickColor = color
	part:SetAttribute('ArenaAutoPart', true)
	return part
end

-- Ensure a runtime ArenaStand carries the interaction parts
-- the canonical systems resolve through StandResolver:
--   Slot/MenuPart/MenuGui -> menus (the UpgradeButton itself
--     is template-provisioned by StandDisplayService, never
--     hand-built here, so arena buttons always match normal
--     stands)
--   Button/Base + Button/PressPart (+ SurfaceGui/Amount)
--     -> cash collection trigger + pool display
-- Anything the authored ArenaStandTemplate already provides
-- is reused untouched; only MISSING structural pieces are
-- created in code (marked ArenaAutoPart=true), positioned
-- relative to the stand root. When the template later ships
-- real parts under the same names, this becomes a silent
-- no-op. Idempotent. Never throws. Returns false only when
-- the stand has no resolvable root part at all.
function DynamicSlotService.EnsureArenaStandParts(stand: Instance): boolean
	local ok = pcall(function()
		if typeof(stand) ~= 'Instance' then
			error('no-stand')
		end
		local parts = StandResolver.GetStandParts(stand)
		local root = parts.root
		if root == nil then
			error('no-root')
		end
		local rootCf = (root :: BasePart).CFrame
		local rootSize = (root :: BasePart).Size
		local groundY = rootCf.Y - rootSize.Y / 2
		local slotNode = parts.slot or stand

		-- Menu chain (only what is missing).
		local menuPart = parts.menuPart
		if menuPart == nil then
			local created = mkArenaPart('MenuPart', Vector3.new(3, 2, 0.5), BrickColor.new('Dark stone grey'))
			created.CanTouch = false
			created.CFrame = rootCf * CFrame.new(0, rootSize.Y / 2 + 2.5, 0)
			created.Parent = slotNode
			menuPart = created
						Debug.Warn('ArenaSlots', ('auto-created MenuPart on %s'):format((stand :: Instance):GetFullName()))
		end
		local menuGui = menuPart ~= nil and (menuPart :: Instance):FindFirstChild('MenuGui', true) or nil
		if menuGui == nil and menuPart ~= nil then
			local createdGui = Instance.new('SurfaceGui')
			createdGui.Name = 'MenuGui'
			createdGui.Face = Enum.NormalId.Top
			createdGui:SetAttribute('ArenaAutoPart', true)
			createdGui.Parent = menuPart
			menuGui = createdGui
		end
		-- No button is auto-created here (or anywhere in this
		-- module): the UpgradeButton comes exclusively from the
		-- shared UpgradeButtonTemplate via StandDisplayService
		-- (same pipeline as normal stands), and no SellButton
		-- exists by design (selling lives on the animal's Sell
		-- prompt; eggs are not sellable).

		-- Cash chain (only what is missing).
		local buttonFolder = (stand :: Instance):FindFirstChild('Button')
		if buttonFolder == nil then
			buttonFolder = Instance.new('Folder')
			buttonFolder.Name = 'Button'
			(buttonFolder :: Instance):SetAttribute('ArenaAutoPart', true)
			buttonFolder.Parent = stand
		end
		local basePart = (buttonFolder :: Instance):FindFirstChild('Base')
		if basePart == nil or not (basePart :: Instance):IsA('BasePart') then
			local created = mkArenaPart('Base', Vector3.new(3, 0.5, 3), BrickColor.new('Dark stone grey'))
			created.CanTouch = false
			created.Position = Vector3.new(rootCf.X + 3.5, groundY + 0.25, rootCf.Z)
			created.Parent = buttonFolder
			basePart = created
		end
		local pressPart = (buttonFolder :: Instance):FindFirstChild('PressPart')
		if pressPart == nil or not (pressPart :: Instance):IsA('BasePart') then
			local created = mkArenaPart('PressPart', Vector3.new(2, 0.5, 2), BrickColor.new('Bright green'))
			created.CanTouch = true
			created.Position = Vector3.new(rootCf.X + 3.5, groundY + 1, rootCf.Z)
			created.Parent = buttonFolder
			pressPart = created
						Debug.Warn('ArenaSlots', ('auto-created cash Button on %s'):format((stand :: Instance):GetFullName()))
		end
		if pressPart ~= nil and (pressPart :: Instance):IsA('BasePart') then
			local surfaceGui = (pressPart :: BasePart):FindFirstChild('SurfaceGui')
			if surfaceGui == nil then
				local createdGui = Instance.new('SurfaceGui')
				createdGui.Name = 'SurfaceGui'
				createdGui.Face = Enum.NormalId.Top
				createdGui:SetAttribute('ArenaAutoPart', true)
				local amount = Instance.new('TextLabel')
				amount.Name = 'Amount'
				amount.BackgroundTransparency = 1
				amount.TextColor3 = StandConfig.AmountLabel.TextColor
				amount.Font = StandConfig.AmountLabel.Font
				amount.TextScaled = true
				amount.Size = UDim2.fromScale(1, 1)
				amount.Text = StandConfig.AmountLabel.InitialText
				amount.Parent = createdGui
				createdGui.Parent = pressPart
			end
		end
	end)
	if not ok then
		warn(('[ArenaSlots] EnsureArenaStandParts failed for %s'):format(tostring(stand)))
		return false
	end
	return true
end

-- Create the runtime arena stands for an assignment. Returns
-- the live count. Never throws. Session-gated on the shared
-- base.session (no second session system).
function DynamicSlotService.BuildArenaStands(base: any, userId: number, session: number): number
	if not checkSession(base, session, 'DynamicArenaStands', 'build') then
		return 0
	end
	local folder = base.folder
	local template = DynamicSlotService.GetArenaTemplate()
	if template == nil then
				Debug.Warn('DynamicArenaStands', ('Base assigned: %s session=%s but the ArenaStandTemplate is unusable; ZERO stands built'):format(
				tostring(base.id),
				tostring(session)
			))
		-- Records still follow live clones (never stale):
		-- whatever stands exist are re-indexed for the
		-- current owner even though no new clones spawn.
		refreshArenaRecords(base, userId)
		return 0
	end
	local markers = DynamicSlotService.GetArenaStandPositions(folder)
	if #markers == 0 then
		-- No markers: whatever (if anything) is live is
		-- re-indexed; normally this yields zero records.
		refreshArenaRecords(base, userId)
		return 0
	end
	local container = ensureContainer(folder, StandResolver.Names.ArenaStandsFolder, base.id, 'DynamicArenaStands')
	if container == nil then
		warn(('[DynamicArenaStands] Base=%s has no folder; cannot build stands'):format(tostring(base.id)))
		return 0
	end
		Debug.Warn('DynamicArenaStands', ('Base assigned: %s session=%s container=%s template=%s'):format(
			tostring(base.id),
			tostring(session),
			(container :: Instance):GetFullName(),
			(template :: Instance):GetFullName()
		))
	local desired = DynamicSlotService.GetDesiredArenaStandCount(folder, userId)
	if desired <= 0 then
		warn(
			('[DynamicArenaStands] Invalid desired arena count (%d) for Base=%s; building nothing'):format(
				desired,
				tostring(base.id)
			)
		)
		return 0
	end
		Debug.Warn('DynamicArenaStands', ('Desired arena count for Base=%s: %d (%d markers)'):format(
			tostring(base.id),
			desired,
			#markers
		))
	local created = createdArenaByBase[base.id]
	if not created then
		created = {}
		createdArenaByBase[base.id] = created
	end
	local live = 0
	-- Generated arena row: base-local centered row through the
	-- base pivot. Ground plane = arena marker average Y.
	local arenaCfg = StandLayoutConfig.Arena
	local arenaBaseCF = layoutCenter(folder)
	if arenaBaseCF == nil then
				Debug.Warn('DynamicArenaStands', ('Base=%s has no usable layout origin; building nothing'):format(tostring(base.id)))
		return 0
	end
	local arenaGroundY = (arenaBaseCF :: CFrame).Y
	-- ARENA TRACK ONLY (straight centered row — never the animal
	-- ring): local Z/Spacing from StandLayoutConfig.Arena, Y exact
	-- Center Y, front axis facing Center. Independent of the
	-- animal track above by design.
	local arenaLocals = StandLayout.ArenaLocals(desired, arenaCfg.Z, arenaCfg.Spacing)
		Debug.Warn('StandLayout', ('Base=%s arenaStands=%d groundY=%.2f'):format(
			tostring(base.id),
			desired,
			(arenaGroundY :: number)
		))
	-- Position one arena stand on its generated row slot, front
	-- axis facing Center (same convention as the animal track;
	-- arena template measured separately).
	local arenaFront = measureFrontOffset(template)
	local arenaCenterPos = (arenaBaseCF :: CFrame).Position
	if arenaFront ~= nil then
				Debug.Warn('StandLayout', ('Base=%s arena front offset=(%.2f, %.2f)'):format(
				tostring(base.id),
				arenaFront.X,
				arenaFront.Z
			))
	end
	local function placeArenaAt(inst: Instance, slotIndex: number): boolean
		local localCF = arenaLocals[slotIndex]
		if localCF == nil then
			return false
		end
		local worldPos = (arenaBaseCF :: CFrame) * Vector3.new(localCF.X, 0, localCF.Z)
		local worldCF = orientTowardCenter(worldPos, arenaCenterPos, arenaFront)
		if worldCF == nil then
			worldCF = (arenaBaseCF :: CFrame) * CFrame.new(localCF.X, 0, localCF.Z)
				* (localCF - localCF.Position)
		end
		if DynamicSlotService.PlaceAtCFrame(inst, worldCF :: CFrame) then
						Debug.Warn('StandLayout', ('Base=%s ArenaStand=%d Position=%.1f, %.1f, %.1f'):format(
					tostring(base.id),
					slotIndex,
					worldCF.X,
					worldCF.Y,
					worldCF.Z
				))
			return true
		end
		return false
	end
	for index = 1, desired do
		local standName = StandResolver.Names.ArenaStandPrefix .. tostring(index)
		local existing: Instance? = nil
		for _, inst in ipairs(created) do
			if inst.Parent ~= nil and inst.Name == standName then
				existing = inst
				break
			end
		end
		if existing == nil then
			local stale = (container :: Instance):FindFirstChild(standName)
			if stale ~= nil and StandResolver.ParseArenaStandIndex(stale.Name) ~= nil then
				existing = stale
				created[#created + 1] = stale
								Debug.Warn('DynamicArenaStands', ('Reusing pre-existing %s for Base=%s session=%s'):format(
						standName,
						tostring(base.id),
						tostring(session)
					))
			end
		end
		if existing == nil then
						Debug.Warn('DynamicArenaStands', ('Cloning ArenaStandTemplate for ArenaStand %d (Base=%s)'):format(
					index,
					tostring(base.id)
				))
			local ok, clone = pcall(function()
				return (template :: Instance):Clone()
			end)
			if not ok or clone == nil then
				warn(
					('[DynamicArenaStands] Failed to clone ArenaStandTemplate for Base=%s stand=%d'):format(
						tostring(base.id),
						index
					)
				)
			else
				local cloneInst = clone :: Instance
				cloneInst.Name = standName
				cloneInst.Parent = container
				if placeArenaAt(clone, index) then
					created[#created + 1] = clone
					existing = clone
										Debug.Warn('DynamicArenaStands', ('Parenting %s -> %s'):format(
							standName,
							(container :: Instance):GetFullName()
						))
				else
					pcall(function()
						(clone :: Instance):Destroy()
					end)
				end
			end
		end
		if existing ~= nil then
			-- Generated layout is authoritative: move reused
			-- stands onto their row slot (arena animals ride
			-- along as stand children).
			placeArenaAt(existing, index)
			-- Interaction parts (menu + cash button) follow
			-- the clone: authored pieces reused, missing
			-- ones auto-created, before records resolve.
			DynamicSlotService.EnsureArenaStandParts(existing)
			live += 1
		end
	end
	-- Records follow clones (same session gate above): the
	-- canonical grab/place pipeline resolves arena slots
	-- through SlotService exactly like normal slots.
	local records = refreshArenaRecords(base, userId)
	-- Cash triggers follow records: the canonical touch ->
	-- TryCollect pipeline wires here, AFTER the records
	-- exist. (Wiring earlier — e.g. before BuildArenaStands
	-- in the assign path — observes the stale/empty array
	-- and silently wires nothing. That ordering gap was the
	-- missing arena cash-collection hookup.) Idempotent per
	-- part; lazy require mirrors the pattern above.
	pcall(function()
		local IncomeService = require(script.Parent.Parent.IncomeService)
		if IncomeService and IncomeService.EnsureCollectorsForSlots then
			IncomeService.EnsureCollectorsForSlots(base.arenaSlots)
		end
	end)
		Debug.Warn('ArenaSlots', ('Base=%s records built: %d (stands live: %d)'):format(tostring(base.id), records, live))
	return live
end

-- Destroy this base's runtime arena stands. Markers, shell,
-- and template untouched. Session-gated. Never throws.
function DynamicSlotService.DestroyArenaStands(base: any, session: number): number
	if not checkSession(base, session, 'DynamicArenaStands', 'destroy') then
		return 0
	end
	local destroyed = 0
	local created = createdArenaByBase[base.id]
	-- Detach cash triggers while the records still exist
	-- (arena collectors wire like normal ones, so they
	-- un-wire the same way — no pinning destroyed parts).
	pcall(function()
		local IncomeService = require(script.Parent.Parent.IncomeService)
		if IncomeService and IncomeService.ForgetCollectorsForSlots then
			IncomeService.ForgetCollectorsForSlots(base.arenaSlots or {})
		end
	end)
	if created then
		for _, inst in ipairs(created) do
			pcall(function()
				(inst :: Instance):Destroy()
			end)
			destroyed += 1
		end
		createdArenaByBase[base.id] = nil
	end
	local ok, folderErr = pcall(function()
		local folder = base.folder
		if typeof(folder) ~= 'Instance' then
			return
		end
		local container = folder:FindFirstChild(StandResolver.Names.ArenaStandsFolder)
		if container == nil then
			return
		end
		for _, child in ipairs((container :: Instance):GetChildren()) do
			if StandResolver.ParseArenaStandIndex(child.Name) ~= nil then
				local already = false
				if created then
					for _, inst in ipairs(created) do
						if inst == child then
							already = true
							break
						end
					end
				end
				if not already then
					child:Destroy()
					destroyed += 1
				end
			end
		end
	end)
	if not ok then
		warn(('[DynamicArenaStands] Arena sweep failed for Base=%s: %s'):format(tostring(base.id), tostring(folderErr)))
	end
	-- Records die with the clones: the next owner must never
	-- resolve a stale arena slot id.
	base.arenaSlots = {}
	if destroyed > 0 then
				Debug.Warn('DynamicArenaStands', ('Destroyed %d runtime arena stands for Base=%s session=%s'):format(
				destroyed,
				tostring(base.id),
				tostring(session)
			))
	end
	return destroyed
end

-- Canonical arena reconcile: create missing, remove extras.
-- Extras with a live occupant are REFUSED (same safety as the
-- Slot track): destroying the stand would destroy the seated
-- animal model and strand its record. Raid-active teams must
-- additionally never be reconciled mid-run (callers gate on
-- ArenaService raid state). Session-gated.
function DynamicSlotService.ReconcileArenaStands(base: any, userId: number, session: number): number
	if not checkSession(base, session, 'DynamicArenaStands', 'reconcile') then
		return 0
	end
	local desired = DynamicSlotService.GetDesiredArenaStandCount(base.folder, userId)
	-- Build is idempotent for survivors (live clones are kept
	-- by name, only missing ones are cloned).
	DynamicSlotService.BuildArenaStands(base, userId, session)
	-- Remove clones above the desired count.
	if createdArenaByBase[base.id] then
		for i = #createdArenaByBase[base.id], 1, -1 do
			local inst = createdArenaByBase[base.id][i]
			local index = StandResolver.ParseArenaStandIndex(inst.Name)
			if index ~= nil and index > desired then
				local occupied = false
				if type(base.arenaSlots) == 'table' then
					for _, record in ipairs(base.arenaSlots) do
						if type(record) == 'table' and record.arenaIndex == index and record.occupantId ~= nil then
							occupied = true
							break
						end
					end
				end
				if occupied then
										Debug.Warn('DynamicArenaStands', ('Refused to destroy occupied %s for Base=%s (animal still seated)'):format(
							inst.Name,
							tostring(base.id)
						))
					continue
				end
				pcall(function()
					(inst :: Instance):Destroy()
				end)
				table.remove(createdArenaByBase[base.id], i)
								Debug.Warn('DynamicArenaStands', ('Destroyed runtime %s for Base=%s (locked by progression)'):format(
						inst.Name,
						tostring(base.id)
					))
			end
		end
	end
	local live = 0
	if createdArenaByBase[base.id] then
		for _, inst in ipairs(createdArenaByBase[base.id]) do
			if inst.Parent ~= nil then
				live += 1
			end
		end
	end
	-- Records follow the surviving clones (extras above the
	-- desired count were just destroyed).
	rebuildArenaRecords(base, userId)
	return live
end

-- TEST-ONLY seam: drop clone tracking + template cache.
function DynamicSlotService._TestReset()
	for key in pairs(createdByBase) do
		createdByBase[key] = nil
	end
	for key in pairs(createdArenaByBase) do
		createdArenaByBase[key] = nil
	end
	cachedTemplate = nil
	cachedArenaTemplate = nil
end

return table.freeze(DynamicSlotService)
