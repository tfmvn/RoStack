--!strict
--!native
--[[
	Egg.HoverMath
	====================
	The single owner of the Egg's vertical placement arithmetic.

	Two placement modes (do not conflate them):

	  * HOVER (center spawn, flight): the Egg holds a CONSTANT
	    `HoverClearance` clearance between the surface below it
	    and its own BOTTOM FACE. It does not bob, does not
	    oscillate, and does not change height during flight. The
	    only vertical motion is following the floor beneath it
	    (ramps, multiple storeys) so the clearance stays
	    constant. `HoverY` / `FloorY` / `HoverCFrameOnSlot` own
	    this mode.

	  * SEATED (slot parking): the Egg sits ON the slot like an
	    Animal sits on its stand — bottom face flush with the
	    slot's top surface, zero gap. `GroundedCFrameOnSlot`
	    owns this mode, and `Settle` (the single slot-parking
	    entry point) uses it. The per-model pivot-to-bottom
	    offset comes from the SAME FloorGeometry helper the
	    ambient/travel systems use, so every Egg size/pivot/
	    authored scale seats correctly with no hardcoded shift.

	The centre Y in hover mode is therefore always derived,
	never authored:

	    centreY = floorY + HoverClearance + blockHeight / 2

	Why a module instead of inline math: before Phase 5 the
	equivalent constant (`BobCenterHeight`) was inlined at 17
	call sites — 8 that built a hover CFrame and 9 that recovered
	a floor Y by subtracting it. Every one had to agree, and the
	`+ size.Y / 2` half was written out longhand at six of them.
	`HoverY` and `FloorY` are exact inverses of each other and are
	the only place the formula appears, so a designer changing
	`HoverClearance` or `EggSize` cannot desynchronise the
	spawn path from the landing path.

	Why bottom-face clearance and not a centre offset: the visible
	gap is what a designer is actually tuning. With a centre
	offset, growing `EggSize` silently eats the gap until the
	egg clips the floor. With a clearance, the gap survives any
	egg size.

	This mirrors `Animal/SlotMath.lua`, which solves the same
	problem for animals (bottom-face alignment via
	`FeetOffsetBelowPrimary` / `StandingCFrameOnSlot`). Animals
	stand ON the slot; slot-parked eggs now SIT on it too. Only
	center/flight eggs hover. Neither module knows about the
	other, and neither reads the other's constants.

	Every function here is pure except `Settle`, which mutates the
	egg record it is handed.
]]

local Constants = require(script.Parent.Constants)
local StandResolver = require(script.Parent.Parent.Parent.ReplicatedStorage.Utility.StandResolver)

local HoverMath = {}

-- --- Block height ----------------------------------------------

-- The egg's authored height in studs.
--
-- Read from the PrimaryPart (the cube itself) rather than
-- `model:GetExtentsSize()`: a decorative child — a glow, a
-- particle emitter's part, a Roll preview parented for a frame —
-- would inflate the bounding box and silently lift the egg off
-- its clearance. The PrimaryPart IS the egg as far as the
-- player's eye is concerned.
--
-- Falls back to the configured `EggSize.Y` when there is no
-- model or no PrimaryPart, so pure-math callers (and tests) can
-- ask for the nominal height without building a model.
function HoverMath.BlockHeight(model: Model?): number
	if model then
		local primary = model.PrimaryPart
		if primary then
			return primary.Size.Y
		end
	end
	return Constants.EggSize.Y
end

-- --- Floor <-> centre ------------------------------------------

-- Given the Y of the surface below the egg, return the centre Y
-- that puts the egg's BOTTOM FACE exactly `HoverClearance`
-- studs above that surface.
function HoverMath.HoverY(floorY: number, model: Model?): number
	return floorY + Constants.HoverClearance + HoverMath.BlockHeight(model) / 2
end

-- The exact inverse of `HoverY`: given an egg's centre Y, recover
-- the Y of the surface it is hovering above. Used wherever the
-- code has a placed egg and needs its local floor back — the
-- replacement for every `centre.Y - BobCenterHeight`.
--
-- `HoverMath.FloorY(HoverMath.HoverY(y, m), m) == y` for all y, m.
function HoverMath.FloorY(centreY: number, model: Model?): number
	return centreY - Constants.HoverClearance - HoverMath.BlockHeight(model) / 2
end

-- --- Slots -----------------------------------------------------

-- The walkable top surface of a slot part: the surface an egg
-- hovering on that slot keeps its clearance above.
function HoverMath.SlotFloorY(slot: any): number
	local part = slot and slot.part
	if not part then
		return 0
	end
	return part.CFrame.Y + part.Size.Y / 2
end

-- The full landing CFrame for an egg on a slot.
--
-- HOVER mode (center spawn / flight destination reference):
-- takes the slot's XZ and faces the stand's button base
-- (`Stand.Button.Base`, yaw-only, no tilt) — and replaces
-- only the Y with the hover height above the slot's top
-- surface. Rotation comes from the button rather than the
-- egg so an egg that arrived at an arbitrary travel yaw
-- snaps to face the button on landing. When the
-- stand/button cannot be resolved, the slot part's own
-- rotation is kept (legacy workspaces, tests).
--
-- NOTE: slot PARKING does not use this — see
-- `GroundedCFrameOnSlot` / `Settle`. This stays for hover
-- contexts only.
function HoverMath.HoverCFrameOnSlot(slot: any, model: Model?): CFrame
	local part = slot and slot.part
	if not part then
		return CFrame.new(0, HoverMath.HoverY(0, model), 0)
	end
	local slotCFrame = part.CFrame
	local rotation = StandResolver.GetSlotFacingRotation(slot)
	local y = HoverMath.HoverY(HoverMath.SlotFloorY(slot), model)
	return CFrame.new(slotCFrame.X, y, slotCFrame.Z) * rotation
end

-- Pivot-to-bottom offset for a model: how far the pivot sits
-- above the model's lowest bottom face. Per-model (never a
-- global egg height), so every size/pivot/authored scale seats
-- correctly with no hardcoded shift.
--
-- Measured in PIVOT-LOCAL space (not world Y): Settle runs
-- after carry/flight paths that can leave the model tilted,
-- and a world-Y measurement would then read the wrong extent.
-- For yaw-only poses this agrees exactly with the world-space
-- FloorGeometry helper the ambient/travel systems use; under
-- tilt it returns the as-authored bottom, which is what seating
-- wants (rotation is reset to yaw-only by the placement
-- itself). Falls back to half the PrimaryPart height (same
-- fallback both other systems use).
function HoverMath.GroundOffset(model: Model?): number
	local fallback = Constants.EggSize.Y / 2
	if model then
		local primary = model.PrimaryPart
		if primary and primary:IsA('BasePart') then
			fallback = primary.Size.Y / 2
		end
		local okPivot, pivot = pcall(function()
			return (model :: Model):GetPivot()
		end)
		if okPivot and typeof(pivot) == 'CFrame' then
			local lowest: number? = nil
			local okParts = pcall(function()
				for _, descendant in ipairs((model :: Model):GetDescendants()) do
					if descendant:IsA('BasePart') then
						local localCF = (pivot :: CFrame):ToObjectSpace(descendant.CFrame)
						local bottom = localCF.Y - descendant.Size.Y / 2
						if lowest == nil or bottom < (lowest :: number) then
							lowest = bottom
						end
					end
				end
			end)
			if okParts and lowest ~= nil then
				-- Unclamped by design: bottom-flush means
				-- pivotY = slotTop - lowestBottom for ANY pivot
				-- authoring (center pivots give a positive
				-- offset; base pivots give ~0; below-geometry
				-- pivots correctly seat the pivot under the
				-- surface). Clamping here would float the egg.
				return -(lowest :: number)
			end
		end
		return fallback
	end
	return fallback
end

-- The SEATED CFrame for an egg on a slot: same XZ/rotation as
-- the hover variant, but the model's BOTTOM FACE rests flush
-- on the slot's top surface (zero gap — the same visual
-- relationship as an Animal standing on its stand). No
-- hardcoded shift: the Y is slotTop + the model's own
-- pivot-to-bottom offset (`GroundOffset`), so every
-- size/pivot/authored scale seats correctly. This is the ONLY
-- correct slot-parking transform; the idle wobble
-- (StandPresentation) animates AROUND the rest pose captured
-- from it and never owns the baseline Y.
function HoverMath.GroundedCFrameOnSlot(slot: any, model: Model?): CFrame
	local part = slot and slot.part
	if not part then
		return CFrame.new(0, HoverMath.GroundOffset(model), 0)
	end
	local slotCFrame = part.CFrame
	local rotation = StandResolver.GetSlotFacingRotation(slot)
	local y = HoverMath.SlotFloorY(slot) + HoverMath.GroundOffset(model)
	return CFrame.new(slotCFrame.X, y, slotCFrame.Z) * rotation
end

-- --- Settle ----------------------------------------------------

-- Park an egg SEATED on `slot` (bottom face flush with the
-- slot's top surface — the same relationship as an Animal on
-- its stand).
--
-- This is the one-line replacement for `BobController.Start(egg)`
-- at every site that used to hand a resting egg to the bob loop.
-- A resting egg now has NO controller: there is nothing to
-- animate, so there is no Heartbeat connection to leak, no tick
-- budget spent, and no controller for a cleanup path to have to
-- recognise and stop.
--
-- The parked pivot is the SEATED CFrame (never a hover CFrame):
-- the idle wobble captures this as its rest baseline and
-- animates around it, so the baseline Y is never owned by,
-- derived from, or accumulated across animation frames.
--
-- Mutates, in order:
--   * the model's pivot        -> the slot's seated CFrame
--   * egg.centerCFrame       -> the same CFrame (the record of
--                                 where the egg IS, read by the
--                                 Roll controller and the refund
--                                 path)
--   * egg._localFloor        -> the slot's top surface
--   * egg.controller         -> nil
--   * egg.controllerType     -> nil
--
-- Callers must have stopped any previous controller first; Settle
-- clears the fields but deliberately does not guess how to stop an
-- arbitrary controller.
--
-- Safe to call with a destroyed or model-less egg: the CFrame
-- fields are still refreshed so the record stays consistent for
-- the cleanup paths that read them.
function HoverMath.Settle(egg: any, slot: any)
	if not egg then
		return
	end
	local model = egg.model
	local cframe = HoverMath.GroundedCFrameOnSlot(slot, model)
	if model and model.Parent and model.PrimaryPart then
		model:PivotTo(cframe)
	end
	egg.centerCFrame = cframe
	egg._localFloor = HoverMath.SlotFloorY(slot)
	egg.controller = nil
	egg.controllerType = nil
end

return table.freeze(HoverMath)
