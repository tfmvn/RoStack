--!strict
--!native
--[[
	tpServer
	Server-side Run for /tp. Loaded by Cmdr's
	Registry:RegisterCommand as commandObject.Run; executes only
	on the server. The shared tp.lua carries the
	definition (Name/Group/Args) and is replicated to the client,
	which forwards execution here through the Cmdr RemoteFunction.
]]

local ServerScriptService = game:GetService('ServerScriptService')

local Debug = require(game.ReplicatedStorage.Utility.Debug)

return function(context, from: Player, to: Player)
	local AdminService = require(ServerScriptService.Admin.AdminService)
	AdminService.AssertAdmin(context.Executor.UserId)
	if not from or not from.Parent then
		return 'The "from" player is not in-game.'
	end
	if not to or not to.Parent then
		return 'The "to" player is not in-game.'
	end
	local fromHrp = from.Character and from.Character:FindFirstChild('HumanoidRootPart')
	local toHrp = to.Character and to.Character:FindFirstChild('HumanoidRootPart')
	if not fromHrp or not fromHrp:IsA('BasePart') then
		return ('%s has no character.'):format(from.Name)
	end
	if not toHrp or not toHrp:IsA('BasePart') then
		return ('%s has no character.'):format(to.Name)
	end
	fromHrp.CFrame = toHrp.CFrame
	Debug.Log('CMDR', 'tp', { from = from.UserId, to = to.UserId, by = context.Executor.UserId })
	return ('Teleported %s -> %s.'):format(from.Name, to.Name)
end
