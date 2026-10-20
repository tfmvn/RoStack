--!strict
--!native
--[[
	speedServer
	Server-side Run for /speed. Loaded by Cmdr's
	Registry:RegisterCommand as commandObject.Run; executes only
	on the server. The shared speed.lua carries the
	definition (Name/Group/Args) and is replicated to the client,
	which forwards execution here through the Cmdr RemoteFunction.
]]

local ServerScriptService = game:GetService('ServerScriptService')

local Debug = require(game.ReplicatedStorage.Utility.Debug)

return function(context, value: number)
	local AdminService = require(ServerScriptService.Admin.AdminService)
	AdminService.AssertAdmin(context.Executor.UserId)
	if type(value) ~= 'number' or value < 0 or value > 200 then
		return 'value must be 0..200.'
	end
	local hum = context.Executor.Character and context.Executor.Character:FindFirstChildOfClass('Humanoid')
	if not hum then
		return 'You have no character.'
	end
	hum.WalkSpeed = value
	Debug.Log('CMDR', 'speed', { value = value, by = context.Executor.UserId })
	return ('WalkSpeed set to %d.'):format(value)
end
