--!strict
--!native
--[[
	RagdollService
	==============
	Server-side R15 ragdoll authority. The core below is the
	provided RagdollModule logic VERBATIM (same order, same
	branches, same waits) — only identifiers/module shape were
	adapted to project conventions. BatService calls
	Ragdoll/Unragdoll/IsRagdolled; the joint work lives ONLY here.

	Faithfulness notes (behavioral deltas vs the reference: none —
	what follows is the complete list of non-logic adaptations):
	  * Function/file names follow project conventions
	    (applyRagdoll/applyGetUp inside Ragdoll/Unragdoll).
	  * Duration/refresh/token/Died scaffolding around the core:
	    the reference leaves recovery timing to its caller
	    (SetRagdoll(character, false)); Bat hits need timed,
	    repeat-safe recovery, so this layer calls the verbatim
	    core and schedules the verbatim reversal.
	  * Strict-mode typing only (no runtime effect).

	Known reference behaviors preserved AS-IS (do not "fix"):
	  * Landing wait: ragdolling a Jumping/Freefalling character
	    BLOCKS until Landed/Running. This can delay the throw;
	    it is the reference's own jump-bug workaround.
	  * task.wait() sequencing inside both directions.
	  * Hardcoded collision restore (no snapshots).
	  * "CollisionPart" branches (no-op on rigs without one).
	  * AnimationConstraint-only release: on non-Upgraded rigs
	    (Motor6D), joints are NOT released — see
	    AvatarJointUpgrade note in the reference header.
]]

local Players = game:GetService('Players')

local Debug = require(game:GetService('ReplicatedStorage').Utility.Debug)

local RagdollService = {}

type RagdollRecord = {
	token: number,
	character: Model,
}

local records: { [Player]: RagdollRecord } = {}
local seq = 0

function RagdollService.IsRagdolled(player: Player): boolean
	return records[player] ~= nil
end

-- Reference DisableJoints + BodyPartsEnabler, in reference order.
-- Releases every AnimationConstraint except "Root", then makes
-- limbs collidable (HRP/CollisionPart stay non-colliding).
local function applyRagdoll(character: Model, humanoid: Humanoid, hrp: BasePart)
	if humanoid:GetState() == Enum.HumanoidStateType.Jumping
		or humanoid:GetState() == Enum.HumanoidStateType.Freefall then
		local landedSignal: RBXScriptConnection? = nil
		landedSignal = humanoid.StateChanged:Connect(function(_oldState: Enum.HumanoidStateType, newState: Enum.HumanoidStateType)
			if newState == Enum.HumanoidStateType.Landed or newState == Enum.HumanoidStateType.Running then
				if landedSignal ~= nil then
					landedSignal:Disconnect()
				end
			end
		end)
		while landedSignal ~= nil and landedSignal.Connected do
			task.wait(0.05)
		end
	end
	hrp:SetNetworkOwner(nil)
	task.wait()
	humanoid:ChangeState(Enum.HumanoidStateType.Physics)
	humanoid.AutoRotate = false
	humanoid.PlatformStand = true
	humanoid:SetStateEnabled(Enum.HumanoidStateType.GettingUp, false)
	for _, j in ipairs(character:GetDescendants()) do
		if j:IsA('AnimationConstraint') and j.Name ~= 'Root' then
			j.Enabled = false
		end
	end
	task.wait(0.1)
	for _, b in ipairs(character:GetChildren()) do
		if b:IsA('BasePart') and (b.Name ~= 'HumanoidRootPart' and b.Name ~= 'CollisionPart') then
			b.CanCollide = true
			b.Massless = false
		elseif b.Name == 'CollisionPart' or b.Name == 'HumanoidRootPart' then
			b.CanCollide = false
		end
	end
	humanoid.PlatformStand = true
end

-- Reference GetUp + SetRagdoll(false) tail, in reference order.
local function applyGetUp(player: Player, character: Model, humanoid: Humanoid, hrp: BasePart)
	humanoid.PlatformStand = false
	hrp.Orientation = Vector3.zero
	humanoid:SetStateEnabled(Enum.HumanoidStateType.GettingUp, true)
	humanoid:ChangeState(Enum.HumanoidStateType.GettingUp)
	for _, b in ipairs(character:GetChildren()) do
		if b:IsA('BasePart') and b.Name ~= 'CollisionPart' then
			b.CanCollide = false
		elseif b.Name == 'CollisionPart' and b:IsA('BasePart') then
			b.CanCollide = true
		end
	end
	for _, b in ipairs(character:GetChildren()) do
		if b:IsA('BasePart') then
			b.AssemblyLinearVelocity = Vector3.zero
			b.AssemblyAngularVelocity = Vector3.zero
		end
	end
	humanoid.PlatformStand = false
	humanoid.AutoRotate = true
	for _, j in ipairs(character:GetDescendants()) do
		if j:IsA('AnimationConstraint') and j.Name ~= 'Root' then
			j.Enabled = true
		end
	end
	task.wait()
	hrp:SetNetworkOwner(player)
end

function RagdollService.Ragdoll(player: Player, duration: number): boolean
	if typeof(player) ~= 'Instance' or not player:IsA('Player') then
		return false
	end
	duration = tonumber(duration) or 0
	if duration ~= duration or duration <= 0 then
		return false
	end
	local character = player.Character
	if character == nil then
		return false
	end
	local humanoid = character:FindFirstChildOfClass('Humanoid')
	local hrp = character:FindFirstChild('HumanoidRootPart')
	if humanoid == nil or hrp == nil or not (hrp :: Instance):IsA('BasePart') then
		Debug.Warn('Bat', 'Ragdoll: character incomplete', { player = player.Name })
		return false
	end
	if (humanoid :: Humanoid).Health <= 0 then
		return false
	end
	if (humanoid :: Humanoid).RigType ~= Enum.HumanoidRigType.R15 then
		Debug.Warn('Bat', 'Ragdoll supports R15 rigs only', { player = player.Name })
		return false
	end
	-- No-refresh policy: an already-ragdolled player is left
	-- alone (return false) so repeated hits can never reset the
	-- recovery timer. Anti-spam windows live in the caller
	-- (BatService target immunity); this layer only guarantees
	-- no duplicate joint work and no state corruption.
	local existing = records[player]
	if existing ~= nil then
		return false
	end
	applyRagdoll(character, humanoid :: Humanoid, hrp :: BasePart)
	seq += 1
	local token = seq
	records[player] = { token = token, character = character }
	pcall(function()
		(humanoid :: Humanoid).Died:Once(function()
			if records[player] ~= nil and (records[player] :: RagdollRecord).token == token then
				records[player] = nil
			end
		end)
	end)
	Debug.Log('Bat', ('ragdoll player=%s duration=%.2f'):format(player.Name, duration))
	task.delay(duration, function()
		RagdollService.Unragdoll(player, token)
	end)
	return true
end

function RagdollService.Unragdoll(player: Player, token: number?): boolean
	local record = records[player]
	if record == nil then
		return false
	end
	if token ~= nil and record.token ~= token then
		return false
	end
	records[player] = nil
	local character = record.character
	local humanoid = character:FindFirstChildOfClass('Humanoid')
	local hrp = character:FindFirstChild('HumanoidRootPart')
	if humanoid == nil or hrp == nil or not (hrp :: Instance):IsA('BasePart') then
		return true
	end
	applyGetUp(player, character, humanoid, hrp :: BasePart)
	Debug.Log('Bat', ('ragdoll recovered player=%s'):format(player.Name))
	return true
end

function RagdollService._TestReset()
	table.clear(records)
end

return table.freeze(RagdollService)
