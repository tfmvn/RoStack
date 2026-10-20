--!strict
--!native
--[[
	flyServer
	Server-side Run for /fly. Loaded by Cmdr's
	Registry:RegisterCommand as commandObject.Run; executes only
	on the server. The shared fly.lua carries the
	definition (Name/Group/Args) and is replicated to the client,
	which forwards execution here through the Cmdr RemoteFunction.
]]

local ServerScriptService = game:GetService('ServerScriptService')

local Debug = require(game.ReplicatedStorage.Utility.Debug)

-- Per-character flight state. Keyed by the character model.
local _flightActive: { [Model]: boolean } = {}

local function endFlight(character: Model)
	local hrp = character:FindFirstChild('HumanoidRootPart')
	if hrp then
		for _, child in ipairs(hrp:GetChildren()) do
			if child:IsA('BodyMover') or child:IsA('AlignPosition') or child:IsA('AlignOrientation') then
				child:Destroy()
			end
		end
	end
	_flightActive[character] = nil
end

local function startFlight(character: Model)
	local hrp = character:FindFirstChild('HumanoidRootPart')
	if not hrp or not hrp:IsA('BasePart') then
		return false
	end
	-- BodyGyro keeps the character upright. BodyPosition holds
	-- it at its current Y (overriding gravity). The Humanoid
	-- still processes movement input, so the WASD keys move
	-- the character through space.
	local bg = Instance.new('BodyGyro')
	bg.MaxTorque = Vector3.new(math.huge, math.huge, math.huge)
	bg.P = 9e4
	bg.Parent = hrp
	local bp = Instance.new('BodyPosition')
	bp.MaxForce = Vector3.new(math.huge, math.huge, math.huge)
	bp.P = 9e4
	bp.Position = hrp.Position
	bp.Parent = hrp
	_flightActive[character] = true
	return true
end

return function(context)
	local AdminService = require(ServerScriptService.Admin.AdminService)
	AdminService.AssertAdmin(context.Executor.UserId)
	local character = context.Executor.Character
	if not character then
		return 'You have no character.'
	end
	if _flightActive[character] then
		endFlight(character)
		Debug.Log('CMDR', 'fly off', { by = context.Executor.UserId })
		return 'Flight disabled.'
	end
	if not startFlight(character) then
		return 'Could not enable flight (no HumanoidRootPart).'
	end
	Debug.Log('CMDR', 'fly on', { by = context.Executor.UserId })
	return 'Flight enabled. Re-run /fly to disable.'
end
