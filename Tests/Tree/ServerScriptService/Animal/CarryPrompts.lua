--!strict
--!native
--[[
	CarryPrompts
	============
	Native ProximityPrompt installer for the unified slot action
	menu. Each prompt lives on the *object* (lucky egg model
	or animal model) for Pickup/Open, and on the *slot part*
	for Place. The model is the player's primary affordance
	for Pickup/Open; the slot grid is the affordance for
	Place. The carried model itself carries no prompt — the
	player walks to the slot they want to drop the object
	into and presses E.

 	Prompt model
 	------------
 	* Lucky egg on a slot   -> Pickup (E) + Open (F)
 	                              (prompts on the egg's model)
 	* Animal on a slot      -> Pickup (E)
 	                              (prompt on the animal's model)
 	* Empty slot on player's  -> Place  (E)
 	  base while carrying       (prompt on the slot part)
 	* Reserved slot the player
 	  just demoted (same-slot
 	  return)                 -> Place  (E)
 	                              (prompt on the slot part)
 	* Center lucky egg      -> Buy    (E)
 	                              (unrelated; lives in
 	                               SpawnService)

	Server-side validation is the single source of truth. The
	prompt fires for any trigger; the handler
	(`Action.SlotActionHandler`) rejects requests that aren't
	legal for the player's current carry state / slot state /
	ownership. That means we install the prompt
	unconditionally on creation; the server decides whether
	the action is allowed.

	For the Place prompt on a slot, the player walks up to
	the slot part (it's a part the player can see and stand
	next to) and presses E. The slot's id is captured by the
	prompt's Triggered closure; the server routes directly to
	SlotActionHandler. The Place prompt is only installed on
	Empty slots (any) and Reserved slots the carrying player
	just demoted (the same-slot-return case).
]]

local ReplicatedStorage = game:GetService('ReplicatedStorage')

local PromptConfig = require(ReplicatedStorage.Config.World.Prompts)
local SlotType = require(ReplicatedStorage.Types.SlotType)
local Debug = require(ReplicatedStorage.Utility.Debug)

local CarryPrompts = {}

-- Canonical prompt tuning lives in PromptConfig. The legacy
-- Prompts.Carry.ActionText keys map to Prompts defs here
-- so existing keycodeFor/uiOffsetFor call sites keep working
-- while reading the canonical values (mirrors asserted equal by
-- ConfigValidator + the consistency spec).
local _ACTION_DEFS: { [string]: any } = {
	Pickup = PromptConfig.AnimalPickup,
	Hatch = PromptConfig.EggHatch,
	Steal = PromptConfig.Steal,
	SellAnimal = PromptConfig.AnimalSell,
	Place = PromptConfig.Place,
}

-- --- Callback registry (server routes actions here) --------------

-- These are the functions each service installs so the prompts
-- can dispatch to the right handler. The custom UI used to
-- fire a RemoteEvent; with native ProximityPrompt, the
-- Triggered callback on the server is the trigger source, and
-- it calls into SlotActionHandler via a small wrapper.
--
-- Pickup is a special case: an Egg on a slot and a
-- Animal on a slot both have a Pickup prompt, but each
-- service owns its own record-lookup. The prompt's install
-- captures its kind; on Triggered we dispatch to the
-- matching callback. A single _grabCallback would route
-- every Pickup (including Egg IDs) through the
-- Animal service, which silently rejects EG_... ids —
-- a regression that surfaced in playtest. Two callbacks
-- + a kind-routed dispatch fixes that.
local _grabCallback: ((Player, string) -> any)? = nil
local _eggGrabCallback: ((Player, string) -> any)? = nil
local _placeCallback: ((Player, string, string) -> any)? = nil
local _hatchCallback: ((Player, string) -> any)? = nil
-- Steal (multiplayer): fired by the Steal prompt on another
-- player's Egg/Animal model. Routed to StealService, which
-- validates ownership/lock/distance server-side. Steal
-- completion is touch-only (collector Touched) — there is
-- deliberately NO deliver/place prompt for stolen objects.
local _stealCallback: ((Player, string, string?) -> any)? = nil

function CarryPrompts.SetGrabPromptCallback(cb: (Player, string) -> any)
	_grabCallback = cb
end

function CarryPrompts.SetEggGrabPromptCallback(cb: (Player, string) -> any)
	_eggGrabCallback = cb
end

function CarryPrompts.SetPlacePromptCallback(cb: (Player, string, string) -> any)
	_placeCallback = cb
end

function CarryPrompts.SetHatchPromptCallback(cb: (Player, string) -> any)
	_hatchCallback = cb
end

function CarryPrompts.GetHatchPromptCallback(): ((Player, string) -> any)?
	return _hatchCallback
end

-- Register the server-side steal dispatcher (StealService).
-- `cb(player, occupantId, kind)` where kind is 'egg'/'animal'.
function CarryPrompts.SetStealPromptCallback(cb: (Player, string, string?) -> any)
	_stealCallback = cb
end

-- Sell (animals only): fired by the Sell prompt on the
-- owner's slotted Animal model. Routed to SellService,
-- which validates ownership/slot/state/arena-lock
-- server-side and runs the canonical sale. Eggs never get
-- a Sell prompt (eggs are not sellable); the installer
-- below refuses non-animal kinds.
local _sellCallback: ((Player, string) -> any)? = nil

-- Register the server-side sell dispatcher (SellService).
-- `cb(player, animalId)`.
function CarryPrompts.SetSellPromptCallback(cb: (Player, string) -> any)
	_sellCallback = cb
end

function CarryPrompts.GetSellPromptCallback(): ((Player, string) -> any)?
	return _sellCallback
end

-- --- Internal helpers ------------------------------------------

-- Every slot record of a base, normal AND arena. The arena
-- array lives outside `base.slots` (income/capacity/HUD stay
-- normal-only), so every prompt-grid walk must cover both.
-- Read-only iteration: never mutates either array.
local function eachSlot(base: any): () -> any?
	local normal = (type(base) == 'table' and type(base.slots) == 'table') and base.slots or {}
	local arena = (type(base) == 'table' and type(base.arenaSlots) == 'table') and base.arenaSlots or {}
	local phase = 0
	local key: any = nil
	return function(): any?
		while true do
			if phase == 0 then
				key = next(normal, key)
				if key == nil then
					phase = 1
					key = nil
				else
					return normal[key]
				end
			else
				key = next(arena, key)
				if key == nil then
					return nil
				end
				return arena[key]
			end
		end
	end
end

-- Resolve the keyboard keycode for a given action name from
-- PromptConfig (canonical). Defaults to E if the action
-- isn't in the table. The keybind string ('E', 'F', ...) is
-- looked up against Enum.KeyCode.
local function keycodeFor(action: string): Enum.KeyCode
	local def = _ACTION_DEFS[action]
	local keybind = if type(def) == 'table' then (def :: any).Keybind else nil
	if type(keybind) == 'string' then
		local kc = (Enum.KeyCode :: any)[keybind]
		if kc then
			return kc
		end
	end
	return Enum.KeyCode.E
end

-- Resolve the per-prompt UIOffset (screen-space Vector2) for a
-- given action. Two prompts parented to the same part stack
-- vertically based on this — without it, Roblox's default
-- 36px stack makes the labels overlap on a held-together pair
-- like Pickup + Open. Returns Vector2.new(0, 0) when the
-- config entry has no UIOffsetY, which keeps single-prompt
-- objects (carried models, animals) anchored to the part.
local function uiOffsetFor(action: string): Vector2
	local def = _ACTION_DEFS[action]
	local y = if type(def) == 'table' then (def :: any).UIOffsetY else nil
	if type(y) == 'number' then
		return Vector2.new(0, y)
	end
	return Vector2.new(0, 0)
end

-- Walk a model and return its PrimaryPart (the part ProximityPrompt
-- must be parented to). Returns nil if the model has no PrimaryPart.
local function primaryPart(model: Model?): BasePart?
	if not model then
		return nil
	end
	return model.PrimaryPart
end

-- Wipe every ProximityPrompt currently parented to a model.
-- Used when a state transition changes the prompt set (e.g.
-- Pickup -> Place when grabbing; Pickup+Open when placing).
--
-- ProximityPrompt children are parented to the model's
-- PrimaryPart (a Part), not to the Model directly. We
-- walk descendants to catch them — iterating
-- `model:GetChildren()` only sees direct children of the
-- Model, which misses the prompts entirely. The previous
-- implementation only worked for Flat models with a
-- single part whose Name matches the model's hierarchy.
function CarryPrompts.RemovePromptsFromModel(model: Model?)
	if not model then
		return
	end
	for _, descendant in ipairs(model:GetDescendants()) do
		if descendant:IsA('ProximityPrompt') then
			descendant:Destroy()
		end
	end
end

-- --- Prompt installers -----------------------------------------

-- Install a Pickup prompt on a world model. Used for both
-- lucky eggs and animals sitting on a slot. The prompt
-- is keyed 'Pickup' and binds to E.
--
-- `kind` is 'egg' or 'animal' — drives the dispatch
-- in the Triggered handler (Egg IDs go through
-- SpawnService, animal IDs go through AnimalService).
-- The server-side validation lives in SlotActionHandler; this
-- function just installs the prompt and wires the
-- `Triggered` callback to dispatch through the handler.
--
-- `ownerUserId` is the player whose base this object is
-- sitting on. It's stamped on the prompt as the
-- `ownerUserId` attribute so the client-side
-- `PromptOwnerFilter` LocalScript can hide this prompt from
-- every other player. Pass `nil` for unowned objects
-- (e.g. a center Available Egg — though in that
-- case we use the global Buy prompt, not Pickup).
function CarryPrompts.InstallPickupPrompt(
	model: Model?,
	occupantId: string?,
	kind: string?,
	slot: any?,
	ownerUserId: number?
)
	local part = primaryPart(model)
	if not part then
		Debug.Warn('CP', 'InstallPickupPrompt: no PrimaryPart', {
			model = model and model.Name or 'nil',
		})
		return
	end
	-- Capture kind in the closure so the Triggered callback
	-- can route to the right grab callback. Without this,
	-- a single shared _grabCallback would route every Pickup
	-- (including Egg IDs) through the animal
	-- service, which silently no-ops on EG_... ids.
	local dispatchKind = kind
	-- Wipe any existing prompt first so we never end up with
	-- a stale one from a prior state. Also unregister any
	-- prior prompt we tracked against the slot.
	if slot and slot.id then
		CarryPrompts._UnregisterPromptsForSlot(slot.id)
	end
	for _, child in ipairs(part:GetChildren()) do
		if child:IsA('ProximityPrompt') then
			child:Destroy()
		end
	end
	local prompt = Instance.new('ProximityPrompt')
	prompt.Name = 'PickupPrompt'
	prompt.ActionText = PromptConfig.AnimalPickup.ActionText
	prompt.ObjectText = model.Name
	prompt.KeyboardKeyCode = keycodeFor('Pickup')
	prompt.UIOffset = uiOffsetFor('Pickup')
	prompt.MaxActivationDistance = PromptConfig.AnimalPickup.MaxActivationDistance
	-- Pick Up requires a hold (single authoritative
	-- constant). Early release = TriggerEnded = no commit.
	prompt.HoldDuration = PromptConfig.AnimalPickup.HoldDuration
	prompt.RequiresLineOfSight = PromptConfig.AnimalPickup.RequiresLineOfSight
	-- Multi-player filter: only the owner should see this
	-- Pickup prompt. Set the attribute unconditionally (even
	-- when nil) so PromptOwnerFilter's "attribute exists
	-- check" can distinguish "global Buy" (no attribute) from
	-- "owned object" (attribute present, possibly nil for
	-- anonymous objects — but we never call Pickup on those).
	if ownerUserId then
		prompt:SetAttribute('ownerUserId', ownerUserId)
	end
	prompt.Triggered:Connect(function(player: Player)
		-- Route by kind: Egg IDs go to the SpawnService
		-- lookup; animal IDs go to the AnimalService
		-- lookup. Each callback then looks up the slotId from
		-- its own registry and dispatches SlotActionHandler.
		if dispatchKind == 'egg' then
			if _eggGrabCallback then
				_eggGrabCallback(player, occupantId :: string)
			end
		else
			if _grabCallback then
				_grabCallback(player, occupantId :: string)
			end
		end
	end)
	-- Parent LAST: DescendantAdded + the client filter tick
	-- can otherwise observe a half-installed prompt (no
	-- attributes yet) and show it to the wrong players for a
	-- tick — the stale-Steal-for-owner flash on rapid
	-- pickup/place. Fully stamped before visible, always.
	prompt.Parent = part
	-- Steal affordance for non-owners (same model, same slot,
	-- same owner). Installed at this single funnel so every
	-- slotted object — Egg or Animal, normal or arena stand,
	-- every spawn/place/recover path — carries it. Visibility
	-- is inverse (non-owners only); the server validates
	-- everything (ownership, lock, distance, atomicity).
	CarryPrompts.InstallStealPrompt(model, occupantId, dispatchKind, ownerUserId)
	-- Sell affordance for the owner (animals only — eggs are
	-- not sellable). Installed at this single funnel so
	-- every slotted animal — normal or arena stand, every
	-- spawn/place/recover path — carries exactly one Sell
	-- prompt next to Pickup. Kind rule mirrors the grab
	-- dispatch below ('egg' vs everything-else-animal, so
	-- legacy 'arrived' animals are covered too). The server
	-- validates everything (ownership, slot, state, arena
	-- lock, atomicity).
	if dispatchKind ~= 'egg' then
		CarryPrompts.InstallSellPrompt(model, occupantId, ownerUserId)
	end
	-- Track this prompt so DisablePickupHatchPromptsForBase
	-- can hide it while the player is carrying.
	if slot and slot.id then
		CarryPrompts._RegisterPickupPrompt(slot.id, prompt)
	end
	Debug.Log('CP', 'InstallPickupPrompt', {
		model = model.Name,
		occupantId = tostring(occupantId),
		kind = tostring(kind),
		slotId = tostring(slot and slot.id),
		ownerUserId = tostring(ownerUserId),
	})
end

-- Install an Open prompt on a lucky-egg model. Keyed 'Hatch',
-- binds to F. The Open action is lucky-egg-only; the prompt
-- is only installed on an Egg model.
--
-- `slot` is the slot record the egg sits on (or nil if
-- not yet associated with a slot, e.g. the egg is on the
-- center area). The slot is used to register the prompt in
-- the per-base prompt registry so it can be hidden while
-- the player is carrying.
--
-- `ownerUserId` is the player whose base this egg sits
-- on. Stamped on the prompt as the `ownerUserId`
-- attribute so the client-side `PromptOwnerFilter`
-- LocalScript hides it from every other player.
function CarryPrompts.InstallHatchPrompt(egg: any, slot: any?, ownerUserId: number?)
	local part = primaryPart(egg and egg.model)
	if not part then
		Debug.Warn('CP', 'InstallHatchPrompt: no PrimaryPart', {
			uniqueId = tostring(egg and egg.uniqueId),
		})
		return
	end
	-- Wipe any existing Open prompt first. We don't wipe
	-- every prompt here because an egg on a slot has both
	-- Pickup and Open; InstallHatchPrompt is called once per
	-- spawn and just needs to set/replace its own prompt.
	for _, child in ipairs(part:GetChildren()) do
		if child:IsA('ProximityPrompt') and child.Name == 'HatchPrompt' then
			child:Destroy()
		end
	end
	local prompt = Instance.new('ProximityPrompt')
	prompt.Name = 'HatchPrompt'
	prompt.ActionText = PromptConfig.EggHatch.ActionText
	prompt.ObjectText = PromptConfig.EggHatch.ObjectText
	prompt.KeyboardKeyCode = keycodeFor('Hatch')
	prompt.UIOffset = uiOffsetFor('Hatch')
	prompt.MaxActivationDistance = PromptConfig.EggHatch.MaxActivationDistance
	-- Hatch stays instant (Pick/Place hold does not apply).
	prompt.HoldDuration = PromptConfig.EggHatch.HoldDuration
	prompt.RequiresLineOfSight = PromptConfig.EggHatch.RequiresLineOfSight
	if ownerUserId then
		prompt:SetAttribute('ownerUserId', ownerUserId)
	end
	prompt.Triggered:Connect(function(player: Player)
		-- Open goes through the registered open callback
		-- (EggService wires it). The callback
		-- validates ownership / state and calls
		-- SlotActionHandler.Handle with the right request
		-- table.
		if _hatchCallback then
			_hatchCallback(player, egg.uniqueId)
		end
	end)
	-- Parent LAST (see InstallPickupPrompt): never observable
	-- half-installed.
	prompt.Parent = part
	-- Track this prompt so DisablePickupHatchPromptsForBase
	-- can hide it while the player is carrying.
	if slot and slot.id then
		CarryPrompts._RegisterHatchPrompt(slot.id, prompt)
	end
	Debug.Log('CP', 'InstallHatchPrompt', {
		uniqueId = tostring(egg.uniqueId),
		slotId = tostring(slot and slot.id),
		ownerUserId = tostring(ownerUserId),
	})
end

-- Install a Steal prompt on a world model owned by ANOTHER
-- player (Egg or Animal on a slot). Keyed 'StealPrompt', binds
-- to E. The prompt is installed alongside Pickup/Open at every
-- slotted-object site (via the InstallPickupPrompt funnel
-- below) so coverage never drifts between kinds.
--
-- Visibility is the INVERSE of Pickup/Open: the client-side
-- `PromptOwnerFilter` shows it only to non-owners (marked by
-- the `stealPrompt` attribute). The server NEVER trusts
-- visibility: the Triggered dispatch validates ownership,
-- Base Lock, distance, and atomicity in StealService.
--
-- `kind` is normalized here ('egg' vs everything-else-animal)
-- because one legacy animal site passes 'arrived'.
function CarryPrompts.InstallStealPrompt(model: Model?, occupantId: string?, kind: string?, ownerUserId: number?)
	local part = primaryPart(model)
	if not part then
		return
	end
	if not occupantId or not ownerUserId then
		return
	end
	local stealKind = if kind == 'egg' then 'egg' else 'animal'
	for _, child in ipairs(part:GetChildren()) do
		if child:IsA('ProximityPrompt') and child.Name == 'StealPrompt' then
			child:Destroy()
		end
	end
	local prompt = Instance.new('ProximityPrompt')
	prompt.Name = 'StealPrompt'
	prompt.ActionText = PromptConfig.Steal.ActionText
	prompt.ObjectText = model.Name
	prompt.KeyboardKeyCode = keycodeFor('Steal')
	prompt.UIOffset = uiOffsetFor('Steal')
	prompt.MaxActivationDistance = PromptConfig.Steal.MaxActivationDistance
	-- Steal keeps its existing instant behavior (Pick/Place hold
	-- does not apply).
	prompt.HoldDuration = PromptConfig.Steal.HoldDuration
	prompt.RequiresLineOfSight = PromptConfig.Steal.RequiresLineOfSight
	-- FAIL-CLOSED default: a freshly installed prompt replicates
	-- with Enabled=true unless we say otherwise, and the
	-- client-side PromptOwnerFilter only re-evaluates on its
	-- 0.25s tick. That gap is the owner-Steal flash on rapid
	-- pickup/place (every place reinstalls this prompt, so spam
	-- replays the flash). Starting disabled closes it: the
	-- owner can NEVER observe this prompt before the filter
	-- runs, and eligible non-owners pick it up on the next tick
	-- (<=0.25s later). Attributes BEFORE parent (see
	-- InstallPickupPrompt) stays as the second layer.
	prompt.Enabled = false
	prompt:SetAttribute('ownerUserId', ownerUserId)
	prompt:SetAttribute('stealPrompt', true)
	local idCopy = occupantId
	prompt.Triggered:Connect(function(player: Player)
		if _stealCallback then
			_stealCallback(player, idCopy, stealKind)
		end
	end)
	prompt.Parent = part
	Debug.Log('CP', 'InstallStealPrompt', {
		model = model.Name,
		occupantId = tostring(occupantId),
		kind = stealKind,
		ownerUserId = tostring(ownerUserId),
		enabledDefault = 'false (filter-gated)',
	})
end

-- Remove the Steal prompt from a model (steal started: the
-- object is being carried, so no one may steal it again).
function CarryPrompts.RemoveStealPromptFromModel(model: Model?)
	if not model then
		return
	end
	local part = primaryPart(model)
	if not part then
		return
	end
	for _, child in ipairs(part:GetChildren()) do
		if child:IsA('ProximityPrompt') and child.Name == 'StealPrompt' then
			child:Destroy()
		end
	end
end

-- Install a Sell prompt on a slotted ANIMAL model. Keyed
-- 'SellPrompt', binds to F (PromptConfig.AnimalSell).
-- Animals only: any other kind is refused (eggs are not
-- sellable — no prompt, no path). Installed alongside
-- Pickup at every slotted-animal site via the
-- InstallPickupPrompt funnel below so coverage never drifts
-- (place / move / steal delivery / recover / reassign all
-- funnel there); the funnel wipes stale prompts first, so
-- reinstalls keep exactly one Sell prompt.
--
-- Visibility is owner-only like Pickup: the `ownerUserId`
-- attribute lets the client-side PromptOwnerFilter hide it
-- from everyone else. The server NEVER trusts visibility:
-- the Triggered dispatch validates ownership, slot, state,
-- arena-lock, and atomicity in SellService.
function CarryPrompts.InstallSellPrompt(model: Model?, occupantId: string?, ownerUserId: number?)
	local part = primaryPart(model)
	if not part then
		Debug.Warn('CP', 'InstallSellPrompt: no PrimaryPart', {
			model = model and model.Name or 'nil',
		})
		return
	end
	if not occupantId then
		return
	end
	for _, child in ipairs(part:GetChildren()) do
		if child:IsA('ProximityPrompt') and child.Name == 'SellPrompt' then
			child:Destroy()
		end
	end
	local prompt = Instance.new('ProximityPrompt')
	prompt.Name = 'SellPrompt'
	prompt.ActionText = PromptConfig.AnimalSell.ActionText
	prompt.ObjectText = model.Name
	prompt.KeyboardKeyCode = keycodeFor('SellAnimal')
	prompt.UIOffset = uiOffsetFor('SellAnimal')
	prompt.MaxActivationDistance = PromptConfig.AnimalSell.MaxActivationDistance
	-- Sell is button-like (like the old menu confirm): no
	-- hold. The server validates + commits atomically.
	prompt.HoldDuration = PromptConfig.AnimalSell.HoldDuration
	prompt.RequiresLineOfSight = PromptConfig.AnimalSell.RequiresLineOfSight
	if ownerUserId then
		prompt:SetAttribute('ownerUserId', ownerUserId)
	end
	local idCopy = occupantId
	prompt.Triggered:Connect(function(player: Player)
		if _sellCallback then
			_sellCallback(player, idCopy)
		end
	end)
	-- Parent LAST: attributes before visible, always (see
	-- InstallPickupPrompt).
	prompt.Parent = part
	Debug.Log('CP', 'InstallSellPrompt', {
		model = model.Name,
		occupantId = tostring(occupantId),
		ownerUserId = tostring(ownerUserId),
	})
end

-- Install a Place prompt on a single slot part. The slot is
-- the player's primary affordance while they're carrying: a
-- Place prompt on every Empty slot of the player's base lets
-- the player walk up to any slot and press E to drop the
-- carried object there. The slot they just took the object
-- from is Reserved (the grab path demoted it via
-- DemoteSlotToReserved) and is also given a Place prompt
-- when its `ownerUserId` matches the carrying player, so the
-- same-slot return is always available.
--
-- The server resolves the destination on trigger by inspecting
-- the slot's id (each prompt's Triggered closure captures
-- `slotId` for routing). The Place prompt is not
-- owner-gated on the prompt itself — the server's
-- SlotActionHandler is the only source of truth and rejects
-- any Place where the slot doesn't belong to the carrying
-- player.
--
-- `playerId` is the carrying player's userId. A slot is
-- eligible for a Place prompt when:
--   * state == 'Empty', OR
--   * state == 'Reserved' AND ownerUserId == playerId (the
--     same-slot-return case).
function CarryPrompts.InstallPlacePromptOnSlot(slot: any, playerId: number?)
	if not slot or not slot.part then
		return
	end
	local part = slot.part
	local eligible = slot.state == 'Empty'
		or (slot.state == 'Reserved' and playerId ~= nil and slot.ownerUserId == playerId)
	if not eligible then
		return
	end
	-- Wipe any existing Place prompt on this slot part
	-- (idempotent re-install).
	for _, child in ipairs(part:GetChildren()) do
		if child:IsA('ProximityPrompt') and child.Name == 'PlacePrompt' then
			child:Destroy()
		end
	end
	local prompt = Instance.new('ProximityPrompt')
	prompt.Name = 'PlacePrompt'
	prompt.ActionText = PromptConfig.Place.ActionText
	prompt.ObjectText = PromptConfig.Place.ObjectText
	prompt.KeyboardKeyCode = keycodeFor('Place')
	prompt.UIOffset = uiOffsetFor('Place')
	prompt.MaxActivationDistance = PromptConfig.Place.MaxActivationDistance
	prompt.HoldDuration = PromptConfig.Place.HoldDuration
	prompt.RequiresLineOfSight = PromptConfig.Place.RequiresLineOfSight
	-- Multi-player filter: this Place prompt belongs to
	-- exactly one carrying player (`playerId`). Stamp it
	-- on the prompt so PromptOwnerFilter can hide it from
	-- every other player walking past the same base. The
	-- server-side _placeCallback still validates ownership
	-- (rejects other players' Place triggers with
	-- 'not-owner'); the attribute is purely the UX hide.
	if playerId then
		prompt:SetAttribute('targetUserId', playerId)
	end
	-- Capture slotId + baseId for the trigger dispatch.
	local slotId = slot.id
	local baseId = slot.baseId
	prompt.Triggered:Connect(function(player: Player)
		if _placeCallback then
			_placeCallback(player, slotId, baseId)
		end
	end)
	-- Parent LAST (see InstallPickupPrompt): never observable
	-- half-installed.
	prompt.Parent = part
end

-- Install a Place prompt on every eligible slot of `base`
-- (normal AND arena — the carrying player walks up to any
-- of them). A slot is eligible when it's Empty (open
-- destination) OR when it's Reserved and owned by `playerId`
-- (the same-slot return case where the player just demoted
-- it by grabbing). The base is the record stored in
-- BaseService.bases. This is called when a carry starts (so
-- the carrying player sees a grid of place affordances on
-- their own base). The function is idempotent:
-- re-installing on a slot that already has a Place prompt
-- wipes the old one and installs fresh.
--
-- `carriedKind` ('egg' | 'animal' | nil) filters the grid:
-- eggs can never land on arena stands, so egg carriers are
-- not shown arena Place prompts (the server rejects arena
-- egg placement regardless — this is purely the UX hide).
function CarryPrompts.InstallPlacePromptsForBase(base: any, playerId: number?, carriedKind: string?)
	if not base or not base.slots then
		return
	end
	for slot in eachSlot(base) do
		if carriedKind == 'egg' and type(slot) == 'table' and (slot :: any).arena == true then
			continue
		end
		CarryPrompts.InstallPlacePromptOnSlot(slot, playerId)
	end
end

-- Remove every Place prompt from `base`'s slot parts. Called
-- when the carry ends (Place succeeds, or the carry is
-- cancelled via recover-on-death / disconnect). Empty slots
-- no longer have a Place prompt; the placed model on the
-- destination slot has its own Pickup prompt.
function CarryPrompts.RemovePlacePromptsForBase(base: any)
	if not base or not base.slots then
		return
	end
	for slot in eachSlot(base) do
		if type(slot) ~= 'table' then
			continue
		end
		if slot.part then
			for _, child in ipairs(slot.part:GetChildren()) do
				if child:IsA('ProximityPrompt') and child.Name == 'PlacePrompt' then
					child:Destroy()
				end
			end
		end
	end
end

-- Per-base registry of currently-installed Pickup/Open
-- prompts. The key is the slot's id (e.g. "u:1:s:3");
-- the value is a table { pickup = ProximityPrompt?,
-- open = ProximityPrompt? }. We use this to disable
-- Pickup/Open affordances while the player is carrying
-- (the carried model already has no prompt; the other
-- placed models on the player's base would otherwise
-- still show their prompts, which is noise).
local installedPrompts: { [string]: { pickup: any?, open: any? } } = {}

-- Record that a Pickup prompt is now installed on the
-- occupant of `slotId`. Called from InstallPickupPrompt so
-- the registry stays in sync.
function CarryPrompts._RegisterPickupPrompt(slotId: string, prompt: any)
	if not slotId then
		return
	end
	local entry = installedPrompts[slotId] or { pickup = nil, open = nil }
	entry.pickup = prompt
	installedPrompts[slotId] = entry
end

-- Record that an Open prompt is now installed on the
-- occupant of `slotId`. Called from InstallHatchPrompt.
function CarryPrompts._RegisterHatchPrompt(slotId: string, prompt: any)
	if not slotId then
		return
	end
	local entry = installedPrompts[slotId] or { pickup = nil, open = nil }
	entry.open = prompt
	installedPrompts[slotId] = entry
end

-- Drop the registry entry for `slotId`. Called when the
-- occupant is removed (Place wipes the old slot's occupant;
-- the registry entry is gone with it).
function CarryPrompts._UnregisterPromptsForSlot(slotId: string)
	if not slotId then
		return
	end
	installedPrompts[slotId] = nil
end

-- Purge every registry entry belonging to `base`'s slots, plus
-- any entry whose prompts are all dead (destroyed without
-- unregister — e.g. model teardown). Called on base
-- release/cleanup so the next owner can never toggle a dead
-- prompt through a stale registry entry. Safe to call
-- repeatedly; unknown/missing entries are no-ops.
function CarryPrompts.ForgetSlotsForBase(base: any)
	if type(base) ~= 'table' or type(base.slots) ~= 'table' then
		return
	end
	for slot in eachSlot(base) do
		if type(slot) == 'table' and type(slot.id) == 'string' then
			installedPrompts[slot.id] = nil
		end
		if type(slot) == 'table' and type(slot.index) == 'number' then
			-- Slot ids are re-stamped per owner; also drop the
			-- zero-stamped variant the release path writes.
			local okZero, zeroId = pcall(SlotType.BuildId, 0, SlotType.Kind.Slot, slot.index)
			if okZero and type(zeroId) == 'string' then
				installedPrompts[zeroId] = nil
			end
		end
	end
	for key, entry in pairs(installedPrompts) do
		if type(entry) ~= 'table' then
			installedPrompts[key] = nil
		else
			local alive = false
			for _, prompt in pairs(entry) do
				if typeof(prompt) == 'Instance' and (prompt :: Instance).Parent ~= nil then
					alive = true
					break
				end
			end
			if not alive then
				installedPrompts[key] = nil
			end
		end
	end
end

-- Disable every Pickup/Open prompt currently registered
-- against `base`'s slots. Used when the player starts
-- carrying: the carried model itself already has no
-- prompt (we wiped it on Grab), but every other placed
-- animal/egg on the base still has its Pickup (and
-- Open, for lucky eggs) prompts visible. While
-- carrying, the server rejects any Pickup/Open request
-- anyway (AlreadyCarrying), but the user shouldn't even
-- see the affordance — it adds noise and confuses the
-- player about which prompt is currently active.
-- Toggling `Enabled` is cheap and reversible: when the
-- carry ends we re-enable the same prompt instances.
function CarryPrompts.DisablePickupHatchPromptsForBase(base: any)
	if not base or not base.slots then
		return
	end
	for slot in eachSlot(base) do
		if type(slot) ~= 'table' then
			continue
		end
		local entry = installedPrompts[slot.id]
		if entry then
			if entry.pickup then
				entry.pickup.Enabled = false
			end
			if entry.open then
				entry.open.Enabled = false
			end
		end
	end
end

-- Re-enable every Pickup/Open prompt currently registered
-- against `base`'s slots. Counterpart to
-- DisablePickupHatchPromptsForBase; called when the carry
-- ends (Place succeeds, or the carry is cancelled).
function CarryPrompts.EnablePickupHatchPromptsForBase(base: any)
	if not base or not base.slots then
		return
	end
	for slot in eachSlot(base) do
		if type(slot) ~= 'table' then
			continue
		end
		local entry = installedPrompts[slot.id]
		if entry then
			if entry.pickup then
				entry.pickup.Enabled = true
			end
			if entry.open then
				entry.open.Enabled = true
			end
		end
	end
end

-- Back-compat shim. Older call sites still call
-- InstallGrabPrompt(slotPart, occupantId). We translate that
-- to a Pickup prompt on the *slot* (which keeps the legacy
-- "E on the slot part" UX working as a no-op for the new
-- flow, since prompts on objects supersede slot-part
-- prompts). New code should call InstallPickupPrompt with a
-- model.
function CarryPrompts.InstallGrabPrompt(slotPart: BasePart?, occupantId: string?)
	if not slotPart then
		return
	end
	for _, child in ipairs(slotPart:GetChildren()) do
		if child:IsA('ProximityPrompt') then
			child:Destroy()
		end
	end
	local prompt = Instance.new('ProximityPrompt')
	prompt.Name = 'PickupPrompt'
	prompt.ActionText = PromptConfig.AnimalPickup.ActionText
	prompt.ObjectText = slotPart.Name
	prompt.KeyboardKeyCode = keycodeFor('Pickup')
	prompt.MaxActivationDistance = PromptConfig.AnimalPickup.MaxActivationDistance
	-- Legacy shim prompt: same Pick hold as the canonical path.
	prompt.HoldDuration = PromptConfig.AnimalPickup.HoldDuration
	prompt.RequiresLineOfSight = PromptConfig.AnimalPickup.RequiresLineOfSight
	prompt.Triggered:Connect(function(player: Player)
		if _grabCallback then
			_grabCallback(player, occupantId :: string)
		end
	end)
	-- Parent LAST (see InstallPickupPrompt).
	prompt.Parent = slotPart
end

-- --- Bulk removers (kept for back-compat) ----------------------

function CarryPrompts.RemoveAllHatchPrompts(_blocksFolder: Folder?)
	-- No-op: prompts now live on individual models, not on a
	-- shared eggs folder. Models get cleaned up via
	-- RemovePromptsFromModel when their state changes.
end

function CarryPrompts.RemoveAllGrabPrompts(_base: any)
	-- No-op: see RemoveAllHatchPrompts. New flow installs
	-- per-model Pickup prompts; there's no shared "all grab
	-- prompts on a base" collection to wipe.
end

function CarryPrompts.RemoveAllPromptsFromBase(_base: any)
	-- No-op for the same reason.
end

function CarryPrompts.RemoveAllPromptsFromSlot(_slotPart: BasePart?)
	-- No-op: prompts live on the model, not on the slot.
end

return table.freeze(CarryPrompts)
