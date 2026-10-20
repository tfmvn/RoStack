--!strict
--!native
--[[
	wipePlayerServer
	Server-side Run for /wipePlayer. Loaded by Cmdr's
	Registry:RegisterCommand as commandObject.Run; executes only
	on the server. The shared wipePlayer.lua carries the
	definition (Name/Group/Args) and is replicated to the client,
	which forwards execution here through the Cmdr RemoteFunction.
]]

local ServerScriptService = game:GetService('ServerScriptService')

local Players = game:GetService('Players')

local Debug = require(game.ReplicatedStorage.Utility.Debug)
local RichTextFormatter = require(game.ReplicatedStorage.Utility.RichTextFormatter)

return function(context, player: Player)
	local AdminService = require(ServerScriptService.Admin.AdminService)
	local BaseService = require(ServerScriptService.BaseService)
	local PlayerService = require(ServerScriptService.PlayerService)
	AdminService.AssertAdmin(context.Executor.UserId)
	if not player or not player.Parent then
		return 'That player is not in-game.'
	end
	local userId = player.UserId
	BaseService.WipePlayerData(userId)
	local newBase = BaseService.AssignBaseForPlayer(userId)
	if newBase then
		PlayerService.AssignBase(userId, newBase.id)
		-- Spawn ownership follows the fresh base (see
		-- BaseService.PointPlayerToBaseSpawn).
		BaseService.PointPlayerToBaseSpawn(player, newBase)
	end
	local snap = BaseService.Snapshot(userId)
	PlayerService.PushState(player, snap)
	-- Server-authoritative admin identity (never a client
	-- value): the Cmdr executor, resolved live. Escaped and
	-- styled via the canonical formatter.
	local adminName: string = 'an admin'
	pcall(function()
		local executor = Players:GetPlayerByUserId(context.Executor.UserId)
		if executor and executor.Name ~= '' then
			adminName = executor.Name
		end
	end)
	local text = RichTextFormatter.Escape('Your data was wiped by ')
		.. RichTextFormatter.Colored(RichTextFormatter.Escape(adminName), RichTextFormatter.AdminHex)
		.. RichTextFormatter.Escape('.')
	PlayerService.Notify(player, 'System', text)
	Debug.Log('CMDR', 'wipeplayer', { target = userId, by = context.Executor.UserId })
	return ('Wiped %s (%d).'):format(player.Name, userId)
end
