--!strict
--[[
	CANONICAL CONFIG (unified architecture).
	Single source of truth for its domain. New code must require this path.
	Values preserved exactly from the pre-migration configs - do NOT rebalance
	without a gameplay review. See Docs/configuration/ for domain docs.
]]
-- Prompts: every ProximityPrompt tunable + Carry action tables.
-- GameConfig.Carry (legacy mirror) is folded in below; GameConfig is deleted.
local SlotType = require(script.Parent.Parent.Parent.Types.SlotType)
--[[
	Prompts
	============
	Single source of truth for every ProximityPrompt's TUNABLE values:
	labels, keybinds, hold durations, activation distances, UI offsets,
	and line-of-sight rules.

	WHAT THIS CONTROLS
	------------------
	How every world interaction FEELS: what the prompt says, which key
	it shows, how long the player must hold, and how close they must be.
	Designers rebalance interaction feel here — never in service code.

	WHAT THIS DOES NOT CONTROL
	--------------------------
	* WHO may use a prompt (ownership / steal-eligibility / validation).
	  Those are server-authoritative rules owned by SlotActionHandler,
	  CarryPrompts, EggService, ArenaService, GearShopService, and the
	  client-side PromptOwnerFilter visibility rules.
	* WHETHER a prompt exists at all (e.g. "eggs have no Sell prompt").
	  Structural gameplay rules remain code-owned.
	* Remote names, datastore keys, internal prompt Names
	  ('PickupPrompt', 'BuyPrompt', ...). Those are wiring, not tuning.

	SERVER AUTHORITY
	---------------
	Prompts replicate to clients, but the server re-validates every
	trigger (distance, ownership, state). Changing a distance or hold
	here changes the HONEST experience; exploiters bypassing prompts
	still hit server-side checks. Values are safe to tune.

	CANONICAL HOME
	------------
	Prompts is the single source of truth for prompt tuning (the legacy
	GameConfig.Carry mirror was folded into Prompts.Carry below and the
	mirror deleted). Change shared values HERE only.

	Units:
	  * HoldDuration* — seconds (0 = instant, fires on press).
	  * MaxActivationDistance* — studs.
	  * UIOffset — Vector2 screen pixels; the Y component stacks two
	    prompts on the same part so they don't overlap (first at -40,
	    second at +40). X is 0 (centered on the part).
]]

local Prompts = {}

-- --- Shared carry tuning (canonical; single source) --------

-- Server-side distance check for grab/place, in studs.
-- Type: number. Required: yes. Valid range: > 0.
-- What it does: how close the player must be to pick up or place.
-- Increase: more forgiving grabs. Decrease: tighter, more "physical".
-- Server authoritative: YES (re-checked on trigger).
Prompts.CarryMaxDistance = 8

-- Seconds the player must hold Pick Up / Place. Native
-- ProximityPrompt HoldDuration: releasing early fires TriggerEnded
-- (no commit); holding the full duration fires Triggered once.
-- Type: number. Required: yes. Valid range: >= 0. Unit: seconds.
-- Server authoritative: YES.
Prompts.CarryHoldDuration = 1

-- --- Per-prompt definitions --------------------------------------------

export type PromptDef = {
	ActionText: string,
	ObjectText: string?,
	HoldDuration: number,
	MaxActivationDistance: number,
	RequiresLineOfSight: boolean,
	-- UIOffset Y in screen pixels. 0 = centered on the part.
	UIOffsetY: number,
	-- Keybind shown on PC + console ('E', 'F'). Mobile hides it.
	Keybind: string,
}

-- Animal / egg pickup from a slot. Owner-only visibility.
-- CURRENT VALUES: 'Pick up' / model name / hold 1s / 8 studs / E / -40.
Prompts.AnimalPickup = {
	ActionText = 'Pick up',
	-- ObjectText is the model's display name (dynamic per animal/egg).
	ObjectText = nil,
	HoldDuration = 1,
	MaxActivationDistance = 8,
	RequiresLineOfSight = false,
	UIOffsetY = -40,
	Keybind = 'E',
}

-- Egg hatching (placed egg -> animal). Owner-only, INSTANT (hold 0).
-- CURRENT VALUES: 'Hatch' / 'Egg' / hold 0 / 8 studs / F / +40.
Prompts.EggHatch = {
	ActionText = 'Hatch',
	ObjectText = 'Egg',
	HoldDuration = 0,
	MaxActivationDistance = 8,
	RequiresLineOfSight = false,
	UIOffsetY = 40,
	Keybind = 'F',
}

-- Stealing another player's animal/egg. Non-owner-only, INSTANT.
-- CURRENT VALUES: 'Steal' / model name / hold 0 / 8 studs / E / 0.
Prompts.Steal = {
	ActionText = 'Steal',
	ObjectText = nil,
	HoldDuration = 2.5,
	MaxActivationDistance = 8,
	RequiresLineOfSight = false,
	UIOffsetY = 0,
	Keybind = 'E',
}

-- Paid door opening on a locked base (Unlock Doors product).
-- Non-owner-only, INSTANT. Server revalidates lock state,
-- ownership, and distance on trigger; client visibility is UX
-- only (PromptOwnerFilter door rule).
-- VALUES: 'Open Door' / 'Locked Base' / hold 0 / 12 studs / E / 0.
Prompts.DoorOpen = {
	ActionText = 'Open Door',
	ObjectText = 'Locked Base',
	HoldDuration = 0,
	MaxActivationDistance = 12,
	RequiresLineOfSight = false,
	UIOffsetY = 0,
	Keybind = 'E',
}

-- Selling an animal (prompt lives on the animal model). INSTANT —
-- the confirmation UI (SellConfirmController) is the real gate.
-- CURRENT VALUES: 'Sell' / model name / hold 0 / 8 studs / F / +40.
Prompts.AnimalSell = {
	ActionText = 'Sell',
	ObjectText = nil,
	HoldDuration = 0.5,
	MaxActivationDistance = 8,
	RequiresLineOfSight = false,
	UIOffsetY = 40,
	Keybind = 'F',
}

-- Placing carried cargo onto an empty/reserved slot. Stamped with
-- the target owner id for the PromptOwnerFilter.
-- CURRENT VALUES: 'Place' / 'Slot' / hold 1s / 8 studs / E / 0.
Prompts.Place = {
	ActionText = 'Place',
	ObjectText = 'Slot',
	HoldDuration = 0,
	MaxActivationDistance = 8,
	RequiresLineOfSight = false,
	UIOffsetY = 0,
	Keybind = 'E',
}

-- Buying a center lucky egg. Global (no owner attribute) so the
-- client filter hides it while the local player carries something.
-- CURRENT VALUES: 'Buy <price>' / 'Egg' / hold 0.4 / 12 studs / E.
-- NOTE: the 12-stud range and 0.4s hold intentionally differ from
-- the 8-stud / 1s carry tuning — center eggs are a shop counter,
-- not inventory handling. Preserve deliberately.
Prompts.CenterEggBuy = {
	-- ActionTextPrefix + formatted price ('Buy $100').
	ActionTextPrefix = 'Buy',
	ObjectText = 'Egg',
	HoldDuration = 0.4,
	MaxActivationDistance = 12,
	RequiresLineOfSight = false,
	UIOffsetY = 0,
	Keybind = 'E',
}

-- Arena entry (Adventurer NPC per base). Instant open.
-- CURRENT VALUES: 'Open Arena' / 'Adventurer' / hold 0 / 12 / E.
Prompts.Arena = {
	ActionText = 'Open Arena',
	ObjectText = 'Adventurer',
	HoldDuration = 0,
	MaxActivationDistance = 12,
	RequiresLineOfSight = false,
	UIOffsetY = 0,
	Keybind = 'E',
}

-- Gear shop entry (Workspace.Map.Shop.PromptPart). Instant open.
-- CURRENT VALUES: 'Open Gear Shop' / hold 0 / 12 studs.
Prompts.GearShop = {
	ActionText = 'Open Gear Shop',
	ObjectText = nil,
	HoldDuration = 0,
	MaxActivationDistance = 12,
	RequiresLineOfSight = false,
	UIOffsetY = 0,
	Keybind = 'E',
}

-- --- Carry visuals --------------------------------------------------------
-- Animal head-carry rigging (CarryController welds the model to the
-- carrier's Head via a Motor6D). Presentation/physics feel, not
-- interaction rules.

Prompts.CarryVisual = {
	-- Vertical clearance in studs between the top of the player's
	-- Head part and the carried animal's pivot (head-local up).
	-- Type: number >= 0. CURRENT: 2.5. Animal-only (eggs ride the
	-- same rig through their own path — see CarryController).
	HeadClearanceStuds = 2.5,
}

-- --- Validation ---------------------------------------------------------

-- Pure validation over this module's own shape. Returns issue
-- strings; empty = valid. Used by ConfigValidator + tests.
function Prompts.Validate(): { string }
	local issues: { string } = {}
	local function checkDef(name: string, def: any, needsObjectText: boolean)
		if type(def) ~= 'table' then
			issues[#issues + 1] = name .. ' is not a table'
			return
		end
		if type(def.ActionText) ~= 'string' or def.ActionText == '' then
			issues[#issues + 1] = name .. '.ActionText must be a non-empty string'
		end
		if needsObjectText and (type(def.ObjectText) ~= 'string' or def.ObjectText == '') then
			issues[#issues + 1] = name .. '.ObjectText must be a non-empty string'
		end
		if type(def.HoldDuration) ~= 'number' or def.HoldDuration ~= def.HoldDuration or def.HoldDuration < 0 then
			issues[#issues + 1] = name .. '.HoldDuration must be a number >= 0'
		end
		if type(def.MaxActivationDistance) ~= 'number' or def.MaxActivationDistance <= 0 then
			issues[#issues + 1] = name .. '.MaxActivationDistance must be a number > 0'
		end
		if type(def.Keybind) ~= 'string' or def.Keybind == '' then
			issues[#issues + 1] = name .. '.Keybind must be a non-empty string'
		end
	end
	if type(Prompts.CarryMaxDistance) ~= 'number' or Prompts.CarryMaxDistance <= 0 then
		issues[#issues + 1] = 'CarryMaxDistance must be a number > 0'
	end
	if type(Prompts.CarryHoldDuration) ~= 'number' or Prompts.CarryHoldDuration < 0 then
		issues[#issues + 1] = 'CarryHoldDuration must be a number >= 0'
	end
	if type(Prompts.CarryVisual.HeadClearanceStuds) ~= 'number' or Prompts.CarryVisual.HeadClearanceStuds < 0 then
		issues[#issues + 1] = 'CarryVisual.HeadClearanceStuds must be a number >= 0'
	end
	checkDef('AnimalPickup', Prompts.AnimalPickup, false)
	checkDef('EggHatch', Prompts.EggHatch, true)
	checkDef('Steal', Prompts.Steal, false)
	checkDef('DoorOpen', Prompts.DoorOpen, true)
	checkDef('AnimalSell', Prompts.AnimalSell, false)
	checkDef('Place', Prompts.Place, true)
	checkDef('Arena', Prompts.Arena, true)
	checkDef('GearShop', Prompts.GearShop, false)
	if type(Prompts.CenterEggBuy) ~= 'table' then
		issues[#issues + 1] = 'CenterEggBuy is not a table'
	else
		checkDef('CenterEggBuy', {
			ActionText = Prompts.CenterEggBuy.ActionTextPrefix,
			ObjectText = Prompts.CenterEggBuy.ObjectText,
			HoldDuration = Prompts.CenterEggBuy.HoldDuration,
			MaxActivationDistance = Prompts.CenterEggBuy.MaxActivationDistance,
			Keybind = Prompts.CenterEggBuy.Keybind,
		}, true)
	end
	return issues
end

-- --- Carry action tables (former GameConfig.Carry) ---
-- Which prompt actions exist per occupant kind + their labels/keybinds.
-- Structural rules stay code-owned (SlotActionHandler); text here is tunable.
Prompts.Carry = {
	Actions = {
		-- Egg: pickup + hatch only. Eggs are NOT sellable —
		-- there is no SellEgg action, prompt, button, or
		-- remote path anywhere.
		[SlotType.OccupantKind.Egg] = { 'Pickup', 'Hatch' },
		-- Animal: pickup + sell prompt (SellAnimal routes the
		-- animal's Sell ProximityPrompt). Animals don't
		-- open; they come pre-rolled.
		[SlotType.OccupantKind.Animal] = { 'Pickup', 'SellAnimal' },
		-- Empty slot: only meaningful while carrying. Place.
		Empty = { 'Place' },
		-- Reserved slot (own carry reservation): Place to
		-- return home. Reserved slots owned by other players
		-- show no actions.
		Reserved = { 'Place' },
	},
	ActionText = {
		-- UIOffset is a Vector2 in screen pixels; the Y
		-- component stacks prompts vertically on the same
		-- part so two stacked prompts (e.g. Pickup + Open
		-- on a placed Egg, Pickup + Sell on an animal) don't
		-- overlap: first prompt at -40 (above), second at
		-- +40 (below). Roblox defaults to a tight 36px
		-- stack; ±40 keeps the labels comfortably separated.
		-- The X component is 0 (centered on the part).
		Pickup = { label = 'Pick up', keybind = 'E', yOffset = -40 },
		Hatch = { label = 'Hatch', keybind = 'F', yOffset = 40 },
		Place = { label = 'Place', keybind = 'E', yOffset = 0 },
		-- Steal (multiplayer): shown ONLY to non-owners via the
		-- steal-prompt marker + PromptOwnerFilter inverse rule.
		-- Same key as Pickup; the two never display together
		-- (Pickup is owner-only, Steal is non-owner-only).
		Steal = { label = 'Steal', keybind = 'E', yOffset = 0 },
		-- Sell prompt (animals only — eggs are not sellable).
		-- The Sell prompt lives on the animal model (F);
		-- the slot menu owns Upgrade only. The old
		-- `SellEgg` entry is gone with egg selling.
		SellAnimal = { label = 'Sell', keybind = 'F', yOffset = 40 },
	},
	PerKind = {
		-- Egg carry + open prompts.
		[SlotType.OccupantKind.Egg] = {
			GrabActionText = 'Grab',
			GrabObjectText = 'Egg',
			PlaceActionText = 'Place',
			PlaceObjectText = 'Empty Slot',
			HatchActionText = 'Hatch',
			HatchObjectText = 'Egg',
			-- The Egg Open prompt is bound to F so it
			-- doesn't collide with E (which is Grab/Place on
			-- the slot part). The two prompts live on
			-- different parts in the world but both are within
			-- the same MaxDistance, so the player can E to
			-- pick up from the slot and F to open a different
			-- egg on the same base.
			HatchKeyCode = Enum.KeyCode.F,
		},
		-- Animal carry prompt (no Open prompt for animals).
		[SlotType.OccupantKind.Animal] = {
			GrabActionText = 'Grab',
			GrabObjectText = 'Animal',
			PlaceActionText = 'Place',
			PlaceObjectText = 'Empty Slot',
		},
	},
}

table.freeze(Prompts.Carry)

return table.freeze(Prompts)
