--!strict
--!native
--[[
	teleportToBaseServer
	Server-side Run for /teleportToBase. Loaded by Cmdr's
	Registry:RegisterCommand as commandObject.Run; executes only
	on the server. The shared teleportToBase.lua carries the
	definition (Name/Group/Args) and is replicated to the client,
	which forwards execution here through the Cmdr RemoteFunction.
]]

local ServerScriptService = game:GetService('ServerScriptService')

local Debug = require(game.ReplicatedStorage.Utility.Debug)

return function(context, player: Player)
	local AdminService = require(ServerScriptService.Admin.AdminService)
	local BaseService = require(ServerScriptService.BaseService)
	AdminService.AssertAdmin(context.Executor.UserId)
	if not player or not player.Parent then
		return 'That player is not in-game.'
	end
	local base = BaseService.GetPlayerBase(player.UserId)
	if not base then
		return ('%s has no base.'):format(player.Name)
	end
	local hrp = context.Executor.Character and context.Executor.Character:FindFirstChild('HumanoidRootPart')
	if not hrp or not hrp:IsA('BasePart') then
		return 'You have no character to teleport.'
	end
	hrp.CFrame = (base.spawnCFrame :: CFrame) + Vector3.new(0, 4, 0)
	Debug.Log('CMDR', 'tptobase', { target = player.UserId, by = context.Executor.UserId })
	return ("Teleported to %s's base."):format(player.Name)
end
