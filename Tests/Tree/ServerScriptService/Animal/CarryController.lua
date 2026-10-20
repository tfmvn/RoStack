--!strict
--!native
--[[
	CarryController
	===============
	Welds the carried animal to the player's Head via a
	Motor6D so the animal rides the head bone through
	every animation with zero per-tick cost. The animal's
	PrimaryPart is joined to the Head, and the Motor6D's
	C0 places the model `HeadClearanceStuds` studs above
	the crown of the head in head-local up.

	Before the Motor6D is created, the animal's parts
	are configured for "rigid accessory" carry — the same
	pattern Roblox uses for hats and backpack gear:

	  1. Massless = true (no mass contribution to the
	     carrying character's center of mass).
	  2. CanCollide = false (no self-collision between
	     the animal and the carrying character's body
	     parts).
	  3. Anchored = false (required for the Motor6D to
	     drive the PrimaryPart; an anchored PrimaryPart
	     refuses to follow a Motor6D).
	  4. Humanoid.PlatformStand = true (the animal's
	     own Humanoid goes passive — no internal state
	     machine forces like jumping, falling, or
	     getting up. The Animator's tracks are still
	     functional: the idle track plays visibly while
	     carried, only the Humanoid state machine is
	     suppressed).
	  5. SetNetworkOwner(player) (the carrying player's
	     client simulates the entire assembly locally,
	     so the physics solver doesn't produce correction
	     packets every frame).

	The first four steps (Massless, CanCollide,
	Anchored, PlatformStand) must complete before
	SetNetworkOwner is called — SetNetworkOwner rejects
	anchored parts, so the parts must be unanchored
	first. The Motor6D is created last, so the physics
	engine never sees a partially-configured assembly.
	The single-frame window where the parts are
	unanchored + not-yet-welded is harmless because the
	Motor6D doesn't exist yet — the parts are free-
	floating for one tick at most.

	On Stop, the carry configuration is reversed:
	Massless stays true (harmless for anchored
	PivotTo), the parts are re-anchored (which
	automatically returns ownership to the server),
	PlatformStand = false, and CanCollide is restored
	to true (the AnimalService re-disables
	collisions as needed for the slotted pose). No
	SetNetworkOwner call is needed on Stop because
	anchored parts are server-owned by definition.

 	Why these five properties matter (full analysis in
 	Docs/decisions/ADR-002-animal-carry.md and the
 	original analysis at AnimalCarryWeldDoc):

	  * Without Massless, the animal's mass shifts
	    the character's center of mass upward, and the
	    physics solver over-corrects on every animation
	    cycle — the camera "ragdolls" because the
	    HumanoidRootPart wobbles.
	  * Without CanCollide = false, the animal's
	    bounding box can collide with the character's
	    own head/torso/arms during animation, producing
	    self-collision jitter that propagates to the
	    HumanoidRootPart and the camera.
	  * Without Anchored = false, the animal is in a
	    contradiction: anchored parts want to stay
	    fixed in world space, the Motor6D wants them
	    to follow the Head, the Head wants to follow
	    the character's physics. This produces the
	    most violent form of camera jumping.
	  * Without PlatformStand, the animal's Humanoid
	    applies internal movement forces (jumping,
	    falling, getting up) that interact with the
	    Motor6D on the Head. Two Humanoids in one
	    assembly is not handled gracefully by the
	    engine.
	  * Without SetNetworkOwner, the animal parts
	    are server-owned and the character is client-
	    owned. The physics solver produces correction
	    packets every frame, causing visible stutter
	    and camera jumps on the client.

	Pose (Phase 1.5 carry, "welded to head via Motor6D"):

	  * Anchor: a Motor6D parented to the player's
	    Head, with Part1 = animal.PrimaryPart.
	    C0 = CFrame.new(0, Head.Size.Y/2 + HeadClearanceStuds, 0)
	         — a PURE positional offset, no rotation.
	    C1 = identity.
	  * The rig's joint solver computes:
	      Part1.CFrame = Part0.CFrame * C0 * C1^-1
	    With C1 = identity and C0 = position-only:
	      Part1.CFrame = Head.CFrame * CFrame.new(0, offset, 0)
	    The animal inherits the head's full orientation
	    (yaw, pitch, roll) through the rig solver. Looking
	    left/right/up/down all track the head automatically
	    — the animal always faces the player's look
	    direction.
	  * C0/C1 are STATIC — no per-tick rewrite. The
	    animal rides the head bone through every
	    character animation with zero per-tick cost.
	  * (Adding any rotation to C0 would double-apply
	    with the head's own rotation: Part1 would face
	    at 2*headYaw at attachment time, facing the wrong
	    direction at any non-zero yaw. This is the same
	    pattern Roblox uses for accessories: pure
	    positional C0, orientation inherited from the
	    rig.)
	  * Animation: the animal's idle animation
	    plays while carried. The Motor6D drives
	    position, but the Animator's tracks are still
	    functional (PlatformStand only suppresses the
	    Humanoid state machine, not the Animator's
	    tracks). The idle track keeps the held animal
	    visibly alive (legs cycle, head bobs) instead
	    of looking like a frozen statue. The walk
	    track is stopped on Start and started by the
	    walk path if the animal later walks to a
	    new slot. A "held overhead" animation on the
	    carrying character can be added later and
	    the animal will ride it via the Motor6D.
	  * Network ownership: SetNetworkOwner(player) on
	    every animal BasePart. The carrying player's
	    client simulates the entire assembly locally.
	    Note: this gives the client cosmetic control
	    over the held model — a malicious client can
	    move the visible model out of position. The
	    server's authority over the carry state
	    (state, carriedBy, slotId) is intact; only the
	    visual model position is client-controlled.
	    The AnimalService reads only the record
	    fields, never the model's world CFrame, so
	    this is acceptable for Phase 1.5 (grab/place
	    only, no theft, no combat).

	Algorithm:
	  1. Configure (two passes; the animal's parts
	     start anchored from the slot state, and
	     SetNetworkOwner rejects anchored parts):
	     a. Pass 1: Massless = true, CanCollide = false,
	        Anchored = false on every BasePart.
	        PlatformStand = true on the animal's Humanoid.
	     b. Pass 2: SetNetworkOwner(player) on every
	        BasePart. Parts are now unanchored, so
	        SetNetworkOwner succeeds.
	  2. Reparent the model to the per-player carried
	     folder (outside the rig hierarchy).
	  3. Snap the model to head-top + clearance via
	     model:PivotTo using the head's FULL CFrame
	     (position and orientation), so the animal
	     starts facing the player's look direction.
	  4. Create the Motor6D parented to Head. C0 is a
	     pure positional offset (no rotation); C1 is
	     identity. The rig's joint solver drives the
	     animal's world orientation from the head.
	  5. On Stop: destroy the Motor6D, then re-anchor
	     the parts. Anchored parts are server-owned by
	     definition, so no SetNetworkOwner(nil) call is
	     needed. CanCollide is restored to true (the
	     AnimalService re-disables collisions as
	     needed for the slot). Massless stays true
	     (harmless).

	State:
	  * `controller.motor` — the Motor6D. Stop destroys it.
	  * `controller.running` — true while the carry is active.

	Edge cases:
	  * Head missing (R15 rig without Head, mid-respawn):
	    `Start` errors. The grab transaction should
	    validate the character has a Head before calling Start.
	  * Model destroyed mid-carry: the engine destroys the
	    Motor6D (Part0 or Part1 gone). `Stop`'s
	    `if motor.Parent` guard handles the race.
	  * Character destroyed mid-carry (death, respawn):
	    the bootstrap `Humanoid.Died` hook calls
	    `RecoverCarriedAnimal`, which calls `Stop`. The
	    Motor6D is destroyed and the carry configuration
    is reversed — cleanly, in the right order.
]]

local Workspace = game:GetService('Workspace')

local PromptConfig = require(script.Parent.Parent.Parent.ReplicatedStorage.Config.World.Prompts)
local Debug = require(script.Parent.Parent.Parent.ReplicatedStorage.Utility.Debug)

local CarryController = {}

-- --- Tunables ----------------------------------------------------

CarryController.HeadClearanceStuds = PromptConfig.CarryVisual.HeadClearanceStuds

-- --- Internal helpers --------------------------------------------

-- Apply the "rigid accessory" carry configuration to every
-- BasePart in the model. The five properties must all
-- be in place before the Motor6D is created, so the
-- physics engine never sees a partially-configured
-- assembly. The caller is responsible for the Motor6D
-- creation.
--
-- Pass 1 unanchors the parts. The animal starts in
-- the anchored slot state, and SetNetworkOwner rejects
-- anchored parts ("Network Ownership API cannot be
-- called on Anchored parts or parts welded to Anchored
-- parts."). Pass 1 sets Anchored = false on every
-- part. Pass 2 then calls SetNetworkOwner(player) on
-- the now-unanchored parts. The reverse direction
-- (_restoreFromCarry) doesn't need a two-pass pattern
-- because anchored parts are server-owned by definition
-- and don't need an explicit SetNetworkOwner(nil) call.
local function _configureForCarry(model: Model, player: Player)
	for _, descendant in ipairs(model:GetDescendants()) do
		if descendant:IsA('BasePart') then
			descendant.Massless = true
			descendant.CanCollide = false
			descendant.Anchored = false
		end
	end
	-- Put the animal's Humanoid in passive state so
	-- the Animator doesn't apply internal state-machine
	-- forces (jumping, falling, getting up) that would
	-- fight the Motor6D on the Head.
	local humanoid = model:FindFirstChildOfClass('Humanoid')
	if humanoid then
		humanoid.PlatformStand = true
	end
	-- Pass 2: hand network ownership to the carrying
	-- player. Parts are unanchored from Pass 1, so
	-- SetNetworkOwner succeeds. The animal's record
	-- (state, carriedBy, slotId) is server-authoritative
	-- and the AnimalService never reads the model's
	-- world CFrame, so this is safe for Phase 1.5
	-- (grab/place only, no combat, no theft).
	if player then
		for _, descendant in ipairs(model:GetDescendants()) do
			if descendant:IsA('BasePart') then
				descendant:SetNetworkOwner(player)
			end
		end
	end
end

-- Reverse the carry configuration: re-anchor for the slot
-- PivotTo, restore PlatformStand. CanCollide is left as-is
-- — the AnimalService re-disables collisions as needed
-- for the slot. Massless stays true (harmless for anchored
-- PivotTo movement; the property never needs to be unset).
--
-- Anchored parts are server-owned by definition, so no
-- SetNetworkOwner(nil) call is needed after re-anchoring
-- (the server already owns the parts). The forward
-- direction (_configureForCarry) does need
-- SetNetworkOwner(player) because the parts are unanchored
-- during carry and need explicit client ownership for
-- smooth physics simulation.
local function _restoreFromCarry(model: Model)
	for _, descendant in ipairs(model:GetDescendants()) do
		if descendant:IsA('BasePart') then
			descendant.Anchored = true
		end
	end
	local humanoid = model:FindFirstChildOfClass('Humanoid')
	if humanoid then
		humanoid.PlatformStand = false
	end
end

local function _stopAllAnimations(animal: any)
	if not animal.animations then
		return
	end
	if animal.animations.walk and animal.animations.walk.IsPlaying then
		animal.animations.walk:Stop()
	end
	if animal.animations.idle and animal.animations.idle.IsPlaying then
		animal.animations.idle:Stop()
	end
end

-- Resolve (and lazily create) the per-player carried folder.
local function _getOrCreateCarriedFolder(userId: number): Folder
	local Animals = Workspace:FindFirstChild('Animals')
	if not Animals then
		Animals = Instance.new('Folder')
		Animals.Name = 'Animals'
		Animals.Parent = Workspace
	end
	local folderName = 'Carried_' .. tostring(userId)
	local folder = Animals:FindFirstChild(folderName)
	if not folder then
		folder = Instance.new('Folder')
		folder.Name = folderName
		folder.Parent = Animals
	end
	return folder
end

-- --- Public API --------------------------------------------------

-- Start a carry. Returns a controller record the caller stores
-- on the animal (`animal.controller` / `animal.controllerType`).
-- The controller configures the animal's parts for
-- "rigid accessory" carry, creates a Motor6D on the player's
-- Head, and welds the animal's PrimaryPart to the head.
-- Zero per-tick cost — the rig's joint solver drives the
-- model.
--
-- Caller MUST have set `animal.state = 'Carried'` and
-- `animal.carriedBy = userId` BEFORE calling Start, and MUST
-- have called `BaseService.ReleaseSlot` on the source slot.
--
-- Failure semantics:
--   * No model: error.
--   * No character: error.
--   * No Head: error. (No fallback — a character without
--     a Head can't carry.)
--   * No PrimaryPart: error.
--   * Any pre-existing Motor6D on the Head named
--     'CarryJoint' is destroyed first (idempotent re-Start).
function CarryController.Start(animal: any, userId: number, character: Model, player: Player?): any
	Debug.Log('CC', '> CarryController.Start', { uniqueId = animal.uniqueId, userId = tostring(userId) })

	local model = animal.model
	if not model then
		error('CarryController.Start: animal has no model', 2)
	end
	if not character then
		error('CarryController.Start: no character', 2)
	end
	local head = character:FindFirstChild('Head')
	if not head or not head:IsA('BasePart') then
		error('CarryController.Start: character has no Head', 2)
	end
	local primary = model.PrimaryPart
	if not primary or not primary:IsA('BasePart') then
		error('CarryController.Start: animal has no PrimaryPart', 2)
	end

	-- Destroy any pre-existing CarryJoint (idempotent re-Start).
	local existing = head:FindFirstChild('CarryJoint')
	if existing then
		existing:Destroy()
	end

	-- Configure for "rigid accessory" carry. Single sync
	-- egg: the five properties are set in order without
	-- yields, and the Motor6D is created AFTER. The physics
	-- engine never sees a partially-configured assembly.
	-- player may be nil in tests; SetNetworkOwner(nil) is
	-- a no-op when there's no target.
	_configureForCarry(model, player)

	-- Reparent to the per-player carried folder so the
	-- model is outside the rig hierarchy. (The Motor6D
	-- is parented to the head, but the model itself is
	-- in the carried folder.)
	local carriedFolder = _getOrCreateCarriedFolder(userId)
	if model.Parent ~= carriedFolder then
		model.Parent = carriedFolder
	end

	-- Snap the model to the desired pose before creating
	-- the Motor6D. The Motor6D's C0 will be a pure
	-- positional offset (no rotation), so the model must
	-- be at the exact position AND orientation the rig
	-- solver will produce on the first frame: head.CFrame
	-- shifted up by headTopOffset in head-local up. Using
	-- the head's full CFrame (not just yaw) means the
	-- animal starts facing the player's look direction
	-- and inherits pitch/roll from the head if the head
	-- tilts during the very first frame.
	local headTopOffset = head.Size.Y / 2 + CarryController.HeadClearanceStuds
	local targetCFrame = head.CFrame * CFrame.new(0, headTopOffset, 0)
	model:PivotTo(targetCFrame)

	-- Stop any in-flight walk, then explicitly start
	-- the idle track. The animal is rigidly attached
	-- to the head via the Motor6D, but the Animator is
	-- still functional — PlatformStand only suppresses
	-- the Humanoid state machine (jumping, falling,
	-- getting up), not the Animator's tracks. The idle
	-- track keeps the held animal visibly alive
	-- (legs cycle, head bobs) instead of looking like
	-- a frozen statue. On place, the place flow
	-- re-plays idle after Stop (Stop stops it via
	-- _stopAllAnimations) so the placed animal's
	-- idle animation is fresh.
	_stopAllAnimations(animal)
	if animal.animations and animal.animations.idle then
		animal.animations.idle.Looped = true
		animal.animations.idle:Play()
	end

	-- Create the Motor6D. C0 is a PURE positional offset
	-- — no rotation. The rig's joint solver computes:
	--   Part1.CFrame = Part0.CFrame * C0 * C1^-1
	-- With C1 = identity and C0 = CFrame.new(0, offset, 0):
	--   Part1.CFrame = Head.CFrame * CFrame.new(0, offset, 0)
	-- The animal inherits the head's full orientation
	-- (yaw, pitch, roll) through the rig solver — looking
	-- left/right/up/down all track the head automatically.
	-- The animal always faces the player's look direction.
	--
	-- (Adding any rotation to C0 would double-apply with
	-- the head's own rotation, producing 2*headYaw at
	-- attachment time — the animal would face the wrong
	-- direction at any non-zero yaw. This is the same
	-- pattern Roblox uses for accessories: pure positional
	-- C0, orientation inherited from the rig.)
	local motor = Instance.new('Motor6D')
	motor.Name = 'CarryJoint'
	motor.Part0 = head
	motor.Part1 = primary
	motor.C0 = CFrame.new(0, headTopOffset, 0)
	motor.C1 = CFrame.new(0, 0, 0)
	motor.MaxVelocity = 0
	motor.DesiredAngle = 0
	motor.Parent = head

	local controller: any = {
		animal = animal,
		userId = userId,
		character = character,
		folder = carriedFolder,
		motor = motor,
		headTopOffset = headTopOffset,
		head = head,
		startedAt = os.clock(),
		running = true,
	}

	Debug.Log('CC', '< CarryController.Start done (Motor6D welded to Head)', { uniqueId = animal.uniqueId })
	return controller
end

-- Idempotent. Destroys the Motor6D, restores the animal's
-- carry configuration (re-anchor, NetworkOwner = nil,
-- PlatformStand = false). The caller is responsible for
-- the snap-to-slot PivotTo AFTER Stop.
function CarryController.Stop(controller: any)
	if not controller then
		return
	end
	controller.running = false

	-- Destroy the Motor6D. If Part0 (head) or Part1
	-- (PrimaryPart) is already gone, the engine has
	-- destroyed the motor for us; the `if motor.Parent`
	-- guard handles the race.
	local motor = controller.motor
	if motor and motor.Parent then
		motor:Destroy()
	end
	controller.motor = nil

	-- Reverse the carry configuration. The animal's
	-- model is now in a stationary state for the slot
	-- PivotTo.
	local animal = controller.animal
	if animal and animal.model and animal.model.Parent then
		_restoreFromCarry(animal.model)
	end
	_stopAllAnimations(animal)

	Debug.Log('CC', 'CarryController.Stop done', { uniqueId = animal and animal.uniqueId })
end

function CarryController.IsRunning(controller: any): boolean
	return controller ~= nil and controller.running == true
end

return table.freeze(CarryController)
