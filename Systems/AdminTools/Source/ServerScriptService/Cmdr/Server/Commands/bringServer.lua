--!strict
--!native
--[[
	bringServer
	Server-side Run for /bring. Loaded by Cmdr's
	Registry:RegisterCommand as commandObject.Run; executes only
	on the server. The shared bring.lua carries the
	definition (Name/Group/Args) and is replicated to the client,
	which forwards execution here through the Cmdr RemoteFunction.
]]

local ServerScriptService = game:GetService('ServerScriptService')

local Debug = require(game.ReplicatedStorage.Utility.Debug)

return function(context, player: Player)
	local AdminService = require(ServerScriptService.Admin.AdminService)
	AdminService.AssertAdmin(context.Executor.UserId)
	if not player or not player.Parent then
		return 'That player is not in-game.'
	end
	local myHrp = context.Executor.Character and context.Executor.Character:FindFirstChild('HumanoidRootPart')
	if not myHrp or not myHrp:IsA('BasePart') then
		return 'You have no character.'
	end
	local theirHrp = player.Character and player.Character:FindFirstChild('HumanoidRootPart')
	if not theirHrp or not theirHrp:IsA('BasePart') then
		return ('%s has no character.'):format(player.Name)
	end
	theirHrp.CFrame = myHrp.CFrame * CFrame.new(0, 0, 4)
	Debug.Log('CMDR', 'bring', { target = player.UserId, by = context.Executor.UserId })
	return ('Brought %s to you.'):format(player.Name)
end
