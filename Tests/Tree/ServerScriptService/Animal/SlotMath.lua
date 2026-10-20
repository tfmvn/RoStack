--!strict
--!native
--[[
	SlotMath
	========
	Pure math helpers for placing an animal on an animal slot.

	Why a separate module:
	  * The "stand flush on the slot top" calculation is shared
	    between AnimalService (rejoin spawn via SpawnFromPersistence)
	    and Animal.WalkController (flight target on arrival). Both
	    need the exact same CFrame, and any drift between the two
	    would mean a rejoin-spawned animal and a walked-in animal
	    sit at different heights.
	  * The math is geometry-only — no service dependencies, no
	    remotes, no events. Extracting it makes the math unit-
	    testable without instantiating the whole service stack,
	    and lets the WalkController avoid reaching into
	    AnimalService for a private helper.

	Exports:
	  * FeetOffsetBelowPrimary(model) — local-Y offset from the
	    PrimaryPart down to the lowest bottom face of any BasePart
	    in the model. Negative for typical models with HRP at the
	    center. Scale-aware: the Humanoid HipHeight branch is
	    multiplied by the model's live canonical scale, so a
	    weight-grown model grounds exactly at its CURRENT size
	    (Model:ScaleTo does not scale the HipHeight property
	    itself).
	  * StandingCFrameOnSlot(model, slot) — PrimaryPart CFrame such
	    that, when the model is placed at this CFrame, its lowest
	    bottom face is flush with the slot part's top surface.

	Both helpers are pure (no side effects, no engine mutation).
]]

local SlotMath = {}

local StandResolver = require(script.Parent.Parent.Parent.ReplicatedStorage.Utility.StandResolver)

-- Compute the local-Y offset from the model's PrimaryPart DOWN
-- to the BOTTOM FACE of the model's lowest descendant part.
-- This is how far below the PrimaryPart the model's "feet"
-- actually touch the ground. Returns 0 if the model has no
-- BaseParts.
--
-- Why the bottom face, not the part center: a 2x2x2 foot whose
-- center is 2 studs below the PrimaryPart has its BOTTOM at 3
-- studs below the PrimaryPart. Placing the PrimaryPart at
-- slotTopY + 2 would still leave the foot's center at slotTopY,
-- but the foot's bottom would be 1 stud sunk into the slot.
-- The bottom-face math fixes this.
--
-- Local offset (not world): the model may be at any world
-- position when this helper is called. We use the PrimaryPart's
-- CFrame as the reference frame, so the result is independent
-- of where the model currently sits. ToObjectSpace handles
-- arbitrary rotations, so this is correct even for models
-- that are tilted.
function SlotMath.FeetOffsetBelowPrimary(model: Model): number
	local primary = model.PrimaryPart
	if not primary then
		return 0
	end
	local primaryCFrame = primary.CFrame
	local lowestBottomOffset = 0

	-- For a model with a Humanoid, use the Humanoid's
	-- HipHeight as the feet offset. HipHeight is Roblox's
	-- authoritative definition of where the character's
	-- feet are relative to the HumanoidRootPart, and it
	-- matches the walk/idle animation's foot placement.
	--
	-- For a standard R15 character, HipHeight defaults to
	-- 2. The actual geometric bottom of the leg parts is
	-- at localY ≈ -2.99 (the part is 2 studs tall, centered
	-- at -1.99). Using the geometric bottom causes a ~1
	-- stud visual float because the walk animation's feet
	-- are placed at HRP - HipHeight, not at the geometric
	-- leg bottom. Using HipHeight aligns the animal's
	-- walking feet with the animation's foot placement.
	--
	-- Why this matters: the animal is anchored + driven
	-- by PivotTo, so the Humanoid's auto-floor-adjust is
	-- disabled. If we use the geometric bottom, the model
	-- floats by the difference between the leg bottom and
	-- HipHeight (~1 stud for standard R15). With HipHeight,
	-- the model sits at the height the walk animation
	-- expects the feet to be.
	local humanoid = model:FindFirstChildOfClass('Humanoid')
	if humanoid and humanoid.HipHeight > 0 then
		-- Scale-aware: Model:ScaleTo scales part geometry and
		-- joint offsets but NOT the HipHeight float property,
		-- while weight growth (AnimalWeight, up to +30%) DOES
		-- ScaleTo the live model. A grown model settled with
		-- the template-scale HipHeight sinks by
		-- HipHeight * (scale - 1) — which is why high-level
		-- animals sat correctly on arrival (settled at scale
		-- 1, then grown with a proportional re-ground) but
		-- sank after any later pickup/place/steal/recovery
		-- (settled at grown scale with a stale offset).
		-- Multiplying by the live canonical scale keeps the
		-- offset exact at the CURRENT model size, with no
		-- per-path Y corrections. Unscaled models report
		-- GetScale() == 1, so template-scale behavior is
		-- unchanged.
		local liveScale = 1
		local okScale, s = pcall(function()
			return model:GetScale()
		end)
		if okScale and type(s) == 'number' and s == s and s > 0 and s ~= math.huge then
			liveScale = s
		end
		return -humanoid.HipHeight * liveScale
	end

	for _, descendant in ipairs(model:GetDescendants()) do
		if descendant:IsA('BasePart') and descendant ~= primary then
			-- Skip fully-invisible parts. Some templates ship
			-- a hidden shadow / hitbox / anchor part below
			-- the actual feet (e.g. a Transparency=1 "Floor"
			-- or a "shadow" disc used for ground projection).
			-- If we counted it, the animal would float
			-- above the ground by that part's depth. Only
			-- visible (or partially visible) parts define
			-- the "feet" plane.
			if descendant.Transparency >= 1 then
				continue
			end
			-- Skip parts worn as Accessories (hats, tools,
			-- shoulder-mounted items). These ride on the
			-- character and aren't part of the body silhouette.
			if descendant.Parent and descendant.Parent:IsA('Accessory') then
				continue
			end
			local localCF = primaryCFrame:ToObjectSpace(descendant.CFrame)
			-- The bottom of the descendant in local Y: local
			-- center Y minus half the part's height.
			local bottomLocalY = localCF.Y - descendant.Size.Y / 2
			if bottomLocalY < lowestBottomOffset then
				lowestBottomOffset = bottomLocalY
			end
		end
	end
	-- Also consider the PrimaryPart's own bottom face. If the
	-- model has no descendants below the PrimaryPart, the
	-- PrimaryPart's bottom is the "feet". For a typical
	-- HumanoidRootPart that's the model's local origin
	-- (HRP bottom = HRP center - HRP.Size.Y/2), which is
	-- often negative for centered HRPs. The PrimaryPart is
	-- always considered (it's the rig's reference frame, not
	-- a stray geometry part), so it can be Transparency=1.
	if primary:IsA('BasePart') then
		local primaryBottomLocalY = -primary.Size.Y / 2
		if primaryBottomLocalY < lowestBottomOffset then
			lowestBottomOffset = primaryBottomLocalY
		end
	end
	return lowestBottomOffset
end

-- Compute the CFrame such that, when the model's PrimaryPart
-- is placed at this CFrame, the model's lowest descendant
-- BOTTOM FACE sits flush with the slot's top surface. This
-- makes the animal "stand on" the slot instead of floating
-- above or sinking into it.
--
-- The math: the PrimaryPart is at slotTopY - feetOffset,
-- where feetOffset is the local-Y offset from the PrimaryPart
-- down to the lowest bottom face (see FeetOffsetBelowPrimary).
-- For a foot 3 studs below the PrimaryPart, feetOffset is -3,
-- so the PrimaryPart lands at slotTopY - (-3) = slotTopY + 3,
-- and the foot's bottom (at PrimaryPart - 3) is exactly at
-- slotTopY.
--
-- The slot's X/Z and yaw are preserved so the animal faces
-- the stand's button base (`Stand.Button.Base`, yaw-only, no
-- tilt). The height math is unchanged: only the horizontal
-- facing direction comes from the button; the Y stays the
-- feet-flush value. When the stand/button cannot be resolved
-- (legacy workspaces, tests), the slot part's own rotation
-- is kept.
function SlotMath.StandingCFrameOnSlot(model: Model, slot: any): CFrame
	local part = slot.part
	local size = part.Size
	local slotTopY = part.CFrame.Y + size.Y / 2
	local feetOffset = SlotMath.FeetOffsetBelowPrimary(model)
	-- feetOffset is negative (e.g. -3 means the lowest
	-- bottom face is 3 studs below the PrimaryPart). We
	-- want the PrimaryPart Y to be slotTopY - feetOffset =
	-- slotTopY + |feetOffset|, so the bottom face lands
	-- exactly on slotTopY.
	local targetPrimaryY = slotTopY - feetOffset
	local partPos = part.Position
	local rotation = StandResolver.GetSlotFacingRotation(slot)
	return CFrame.new(partPos.X, targetPrimaryY, partPos.Z) * rotation
end

return table.freeze(SlotMath)
