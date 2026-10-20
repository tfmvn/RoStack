--!strict
--[[
	Carry — consolidated tunables
	=============================

	A single Luau module that consolidates every tunable the Carry
	system reads, so a new game has ONE place to look.

	IMPORTANT — READ BEFORE USING
	-----------------------------
	These values are COPIES. The production game reads them from
	`ReplicatedStorage.Config.World.Prompts` (see
	`Source/ReplicatedStorage/Config/World/Prompts.lua`), which is
	owned by this system's folder. This file is a documentation
	carrier and a starting point, NOT a live config: nothing in the
	shipped source requires it.

	To adopt it as the real config:
	  1. Copy this file to `ReplicatedStorage/Config/Carry.lua`.
	  2. Change the requires in `CarryRegistry`, `ToolLockService`,
	     `ResetProtectionService`, `PlayerGrabService`, and every
	     consumer of `Prompts` to point at it, OR
	  3. Keep `ReplicatedStorage/Config/World/Prompts.lua` as the
	     single source of truth and use this file only as the
	     reference table (recommended — `Prompts` is also read by
	     the Inventory system's dispatcher, the Stealing system, the
	     Arena system, the Items system, and the client prompt
	     controllers).

	EVERY VALUE BELOW IS A PLACEHOLDER UNTIL YOU TUNE IT. The
	"default" column states the value as shipped in Brainrot Arena.
]]

local CarryConfig = {}

-- ---------------------------------------------------------------------------
-- Shared carry tuning
-- ---------------------------------------------------------------------------

-- Server-side distance check for grab/place, in studs.
-- Default: 8
-- Meaning: how close the player must be to pick up or place a carried
--          object. The server re-checks on every trigger; the prompt's
--          own MaxActivationDistance is a separate (client-visible)
--          number.
-- Valid range: > 0. Studs.
-- Safe to change: YES. It changes how forgiving grabs feel. It does not
--                 change the security model (ownership and state are
--                 still checked server-side).
-- Read by:  CarryRegistry (no — this is the shared source read by
--            CarryPrompts / the Inventory system's SlotActionHandler),
--            the world prompt builders.
-- Placeholder: NO — this is the shipped value.
CarryConfig.CarryMaxDistance = 8

-- Seconds the player must hold Pick Up / Place.
-- Default: 1
-- Meaning: the hold length of the carry prompts. Releasing early fires
--          TriggerEnded (no commit); holding the full duration fires
--          Triggered once.
-- Valid range: >= 0. Seconds. 0 = instant.
-- Safe to change: YES.
-- Read by:  the world prompt builders (Prompts.AnimalPickup /
--            Prompts.Place also carry their own HoldDuration).
-- Placeholder: NO.
CarryConfig.CarryHoldDuration = 1

-- ---------------------------------------------------------------------------
-- Carry visuals
-- ---------------------------------------------------------------------------

CarryConfig.CarryVisual = {
	-- Vertical clearance in studs between the top of the player's Head
	-- part and the carried animal's pivot (head-local up).
	-- Default: 2.5
	-- Meaning: how high the carried object floats above the player's
	--          head. Animal-only in practice; eggs ride the same rig
	--          through their own path.
	-- Valid range: >= 0. Studs.
	-- Safe to change: YES — presentation only.
	-- Read by:  CarryController (the client-side welder), which is NOT
	--            part of this system.
	-- Placeholder: NO.
	HeadClearanceStuds = 2.5,
}

-- ---------------------------------------------------------------------------
-- Action allowlist — the shared contract between the client UI and the
-- server dispatcher.
-- ---------------------------------------------------------------------------

-- Which prompt actions exist per occupant kind + slot state.
-- Default: see below.
-- Meaning: the SINGLE source of truth for "which actions exist for this
--          (kind, state) tuple". The Inventory system's
--          `SlotActionHandler` uses it as its server-side allowlist; the
--          client prompt controllers use it to decide which buttons to
--          render.
-- Valid range: a list of action name strings. The action names must
--              match the branches in `SlotActionHandler.Handle`
--              ('Pickup', 'Hatch', 'Place', 'SellAnimal', 'Sell').
-- Safe to change: CAREFULLY. Adding a name here does NOT make the
--                 server accept it — you must also add a dispatch
--                 branch, or the request is rejected as 'InvalidAction'.
--                 Removing a name makes the server reject it.
-- Read by:  SlotActionHandler (Inventory system), the prompt builders,
--            the client prompt UI.
-- Placeholder: NO.
CarryConfig.Actions = {
	-- Egg: pickup + hatch only. Eggs are NOT sellable — there is no
	-- SellEgg action, prompt, button, or remote path anywhere.
	egg = { 'Pickup', 'Hatch' },
	-- Animal: pickup + the animal's own Sell prompt. Animals do not
	-- open; they come pre-rolled.
	animal = { 'Pickup', 'SellAnimal' },
	-- Empty slot: only meaningful while carrying. Place.
	Empty = { 'Place' },
	-- Reserved slot (the player's own carry reservation): Place to
	-- return home. Reserved slots owned by other players show no
	-- actions.
	Reserved = { 'Place' },
}

-- Display labels and keybinds for each action.
-- Default: see below.
-- Meaning: purely cosmetic — the button text and the key shown on PC
--          and console. Mobile hides the keybind.
-- Valid range: non-empty strings; the keybind should be a real
--              Enum.KeyCode name.
-- Safe to change: YES.
-- Read by:  the client prompt UI.
-- Placeholder: NO.
CarryConfig.ActionText = {
	-- label / keybind / screen-pixel Y offset. The Y stacks two prompts
	-- on the same part so they do not overlap (first at -40, second at
	-- +40). X is always 0 (centred).
	Pickup = { label = 'Pick up', keybind = 'E', yOffset = -40 },
	Hatch = { label = 'Hatch', keybind = 'F', yOffset = 40 },
	Place = { label = 'Place', keybind = 'E', yOffset = 0 },
	-- Shown ONLY to non-owners. Same key as Pickup; the two never
	-- display together.
	Steal = { label = 'Steal', keybind = 'E', yOffset = 0 },
	-- The Sell prompt lives on the animal model.
	SellAnimal = { label = 'Sell', keybind = 'F', yOffset = 40 },
}

-- Per-kind carry prompt text.
-- Default: see below.
-- Meaning: the grab / place / hatch prompt wording per occupant kind.
-- Valid range: non-empty strings.
-- Safe to change: YES.
-- Read by:  the client prompt builders.
-- Placeholder: NO.
CarryConfig.PerKind = {
	egg = {
		GrabActionText = 'Grab',
		GrabObjectText = 'Egg',
		PlaceActionText = 'Place',
		PlaceObjectText = 'Empty Slot',
		HatchActionText = 'Hatch',
		HatchObjectText = 'Egg',
		-- F, so it does not collide with E (Grab/Place on the slot
		-- part). Both prompts are within the same MaxDistance, so the
		-- player can E to pick up from a slot and F to hatch a
		-- different egg on the same base.
		HatchKeyCode = Enum.KeyCode.F,
	},
	animal = {
		GrabActionText = 'Grab',
		GrabObjectText = 'Animal',
		PlaceActionText = 'Place',
		PlaceObjectText = 'Empty Slot',
	},
}

-- ---------------------------------------------------------------------------
-- Per-prompt definitions used by the carry flow
-- ---------------------------------------------------------------------------

-- The pick-up prompt on a placed animal or egg.
-- Default: hold 1s / 8 studs / key E / Y offset -40.
-- Meaning: the prompt the player holds to lift an object off a stand.
-- Valid range: HoldDuration >= 0 seconds; MaxActivationDistance > 0
--              studs; UIOffsetY any number; Keybind a KeyCode name.
-- Safe to change: YES. The server re-validates distance and ownership
--                 on trigger regardless.
-- Read by:  the world prompt builders.
-- Placeholder: NO.
CarryConfig.AnimalPickup = {
	ActionText = 'Pick up',
	ObjectText = nil, -- dynamic: the model's display name
	HoldDuration = 1,
	MaxActivationDistance = 8,
	RequiresLineOfSight = false,
	UIOffsetY = -40,
	Keybind = 'E',
}

-- The hatch prompt on a placed egg. Owner-only, instant.
-- Default: hold 0s / 8 studs / key F / Y offset +40.
-- Meaning: opens the egg into an animal.
-- Safe to change: YES.
-- Read by:  the world prompt builders.
-- Placeholder: NO.
CarryConfig.EggHatch = {
	ActionText = 'Hatch',
	ObjectText = 'Egg',
	HoldDuration = 0,
	MaxActivationDistance = 8,
	RequiresLineOfSight = false,
	UIOffsetY = 40,
	Keybind = 'F',
}

-- The place prompt on an empty or reserved slot.
-- Default: hold 0s / 8 studs / key E / Y offset 0.
-- Meaning: puts the carried object down.
-- Safe to change: YES.
-- Read by:  the world prompt builders.
-- Placeholder: NO.
CarryConfig.Place = {
	ActionText = 'Place',
	ObjectText = 'Slot',
	HoldDuration = 0,
	MaxActivationDistance = 8,
	RequiresLineOfSight = false,
	UIOffsetY = 0,
	Keybind = 'E',
}

-- The sell prompt on an animal model. Instant — the confirmation UI is
-- the real gate.
-- Default: hold 0.5s / 8 studs / key F / Y offset +40.
-- Meaning: opens the sell confirmation. Selling itself goes through
--          SlotActionHandler 'SellAnimal' -> SellService.
-- Safe to change: YES.
-- Read by:  the world prompt builders.
-- Placeholder: NO.
CarryConfig.AnimalSell = {
	ActionText = 'Sell',
	ObjectText = nil, -- dynamic: the model's display name
	HoldDuration = 0.5,
	MaxActivationDistance = 8,
	RequiresLineOfSight = false,
	UIOffsetY = 40,
	Keybind = 'F',
}

-- The steal prompt on another player's object. Non-owner-only.
-- Default: hold 2.5s / 8 studs / key E / Y offset 0.
-- Meaning: starts a steal. The long hold is deliberate friction.
-- Safe to change: YES.
-- Read by:  the Stealing system.
-- Placeholder: NO.
CarryConfig.Steal = {
	ActionText = 'Steal',
	ObjectText = nil,
	HoldDuration = 2.5,
	MaxActivationDistance = 8,
	RequiresLineOfSight = false,
	UIOffsetY = 0,
	Keybind = 'E',
}

-- ---------------------------------------------------------------------------
-- Derived-service behaviour
-- ---------------------------------------------------------------------------
-- These are HARD-CODED in the source, not config-driven. They are listed
-- here because a new game usually wants to know they exist.

-- The animation priority the carry pose plays at.
-- Default: Enum.AnimationPriority.Action4
-- Meaning: Action4 is the highest non-Core tier. It outranks the stock
--          Animate script's Idle/Movement locomotion AND other gameplay
--          Action tracks, so the carry pose cannot be overridden while
--          held. Core is deliberately unused.
-- Valid range: any AnimationPriority.
-- Safe to change: YES, but lowering it below the locomotion tracks lets
--                 the pose be overridden. Action4 requires the authored
--                 clip to be UPPER-BODY-ONLY — a lower-body track in
--                 the clip freezes the character's legs.
-- Read by:  PlayerGrabService (hard-coded, not configurable today).
-- Placeholder: NO.
CarryConfig.GrabAnimationPriority = Enum.AnimationPriority.Action4

-- The fade time, in seconds, for starting and stopping the carry pose.
-- Default: 0.1
-- Meaning: how fast the Grab track blends in and out.
-- Safe to change: YES.
-- Read by:  PlayerGrabService (hard-coded).
-- Placeholder: NO.
CarryConfig.GrabFadeSeconds = 0.1

-- The path of the authored carry animation in ServerStorage.
-- Default: ServerStorage.Assets.Animations.Player.Grab
-- Meaning: the ONLY asset this system needs. It is resolved by
--          FindFirstChild, never cloned, and its AnimationId is never
--          hard-coded. A missing asset is a warn, not an error — the
--          carry still works, just without a pose.
-- Safe to change: YES (if you also change PlayerGrabService's
--                 resolveAsset).
-- Read by:  PlayerGrabService (hard-coded).
-- Placeholder: NO.
CarryConfig.GrabAnimationPath = 'ServerStorage.Assets.Animations.Player.Grab'

-- ---------------------------------------------------------------------------
-- Validation
-- ---------------------------------------------------------------------------

--- Check this module's own shape. Returns an array of issue strings;
--- empty means valid.
function CarryConfig.Validate(): { string }
	local issues: { string } = {}

	local function positiveNumber(path: string, v: any)
		if type(v) ~= 'number' or v ~= v or v <= 0 then
			issues[#issues + 1] = path .. ' must be a number > 0'
		end
	end

	local function nonNegativeNumber(path: string, v: any)
		if type(v) ~= 'number' or v ~= v or v < 0 then
			issues[#issues + 1] = path .. ' must be a number >= 0'
		end
	end

	local function nonEmptyString(path: string, v: any)
		if type(v) ~= 'string' or v == '' then
			issues[#issues + 1] = path .. ' must be a non-empty string'
		end
	end

	positiveNumber('CarryMaxDistance', CarryConfig.CarryMaxDistance)
	nonNegativeNumber('CarryHoldDuration', CarryConfig.CarryHoldDuration)
	nonNegativeNumber('CarryVisual.HeadClearanceStuds', CarryConfig.CarryVisual.HeadClearanceStuds)

	if type(CarryConfig.Actions) ~= 'table' then
		issues[#issues + 1] = 'Actions must be a table'
	else
		for _, key in ipairs({ 'egg', 'animal', 'Empty', 'Reserved' }) do
			local list = (CarryConfig.Actions :: any)[key]
			if type(list) ~= 'table' or #list == 0 then
				issues[#issues + 1] = 'Actions.' .. key .. ' must be a non-empty list'
			end
		end
		-- Eggs must never be sellable.
		for _, action in ipairs(CarryConfig.Actions.egg) do
			if action == 'SellAnimal' or action == 'SellEgg' then
				issues[#issues + 1] = 'Actions.egg must not contain a sell action'
			end
		end
	end

	if type(CarryConfig.ActionText) ~= 'table' then
		issues[#issues + 1] = 'ActionText must be a table'
	else
		for _, key in ipairs({ 'Pickup', 'Hatch', 'Place', 'Steal', 'SellAnimal' }) do
			local entry = (CarryConfig.ActionText :: any)[key]
			if type(entry) ~= 'table' then
				issues[#issues + 1] = 'ActionText.' .. key .. ' must be a table'
			else
				nonEmptyString('ActionText.' .. key .. '.label', entry.label)
				nonEmptyString('ActionText.' .. key .. '.keybind', entry.keybind)
				nonNegativeNumber('ActionText.' .. key .. '.yOffset', entry.yOffset)
			end
		end
	end

	if type(CarryConfig.PerKind) ~= 'table' then
		issues[#issues + 1] = 'PerKind must be a table'
	else
		for _, key in ipairs({ 'egg', 'animal' }) do
			local entry = (CarryConfig.PerKind :: any)[key]
			if type(entry) ~= 'table' then
				issues[#issues + 1] = 'PerKind.' .. key .. ' must be a table'
			end
		end
	end

	for _, name in ipairs({ 'AnimalPickup', 'EggHatch', 'Place', 'AnimalSell', 'Steal' }) do
		local def = (CarryConfig :: any)[name]
		if type(def) ~= 'table' then
			issues[#issues + 1] = name .. ' must be a table'
		else
			nonEmptyString(name .. '.ActionText', def.ActionText)
			nonNegativeNumber(name .. '.HoldDuration', def.HoldDuration)
			positiveNumber(name .. '.MaxActivationDistance', def.MaxActivationDistance)
			nonEmptyString(name .. '.Keybind', def.Keybind)
		end
	end

	nonNegativeNumber('GrabFadeSeconds', CarryConfig.GrabFadeSeconds)
	nonEmptyString('GrabAnimationPath', CarryConfig.GrabAnimationPath)

	return issues
end

return table.freeze(CarryConfig)
