--!strict
--!native
--[[
	setLevelServer
	Server-side Run for /setLevel. Loaded by Cmdr's
	Registry:RegisterCommand as commandObject.Run; executes only
	on the server. The shared setLevel.lua carries the
	definition (Name/Group/Args) and is replicated to the client,
	which forwards execution here through the Cmdr RemoteFunction.
]]

local ServerScriptService = game:GetService('ServerScriptService')

local Progression = require(game.ReplicatedStorage.Config.Creatures.Progression)

local Debug = require(game.ReplicatedStorage.Utility.Debug)

local Rarity = require(game.ReplicatedStorage.Types.RarityType)

local function isValidRarity(r: string): boolean
	return r == Rarity.Common
		or r == Rarity.Uncommon
		or r == Rarity.Rare
		or r == Rarity.Epic
		or r == Rarity.Mythic
		or r == Rarity.Legendary
		or r == Rarity.Divine
		or r == Rarity.Secret
end

return function(context, player: Player, rarity: string, level: number)
	local AdminService = require(ServerScriptService.Admin.AdminService)
	AdminService.AssertAdmin(context.Executor.UserId)
	if not player or not player.Parent then
		return 'That player is not in-game.'
	end
	if not isValidRarity(rarity) then
		return 'Unknown rarity.'
	end
	if type(level) ~= 'number' or level < 1 or level > Progression.AdminLevelCap then
		return ('level must be 1..%d.'):format(Progression.AdminLevelCap)
	end
	-- Intentional no-op: per-defId level system is not built yet.
	-- Logged for audit and so a designer can see the command
	-- registered. The next phase wires a real storage slot.
	Debug.Log(
		'CMDR',
		'setlevel (no-op placeholder)',
		{ target = player.UserId, rarity = rarity, level = level, by = context.Executor.UserId }
	)
	return ('setlevel is a placeholder; would set %s %s -> %d.'):format(player.Name, rarity, level)
end
