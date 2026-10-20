--!strict
--!native
--[[
	givexpServer
	Server-side Run for /givexp. Loaded by Cmdr's
	Registry:RegisterCommand as commandObject.Run; executes only
	on the server. The shared givexp.lua carries the
	definition (Name/Group/Args) and is replicated to the client,
	which forwards execution here through the Cmdr RemoteFunction.
]]

local ServerScriptService = game:GetService('ServerScriptService')

local Debug = require(game.ReplicatedStorage.Utility.Debug)
local LevelConfig = require(game.ReplicatedStorage.Config.Creatures.Progression)

return function(context, player: Player, animalId: string, amount: number)
	local AdminService = require(ServerScriptService.Admin.AdminService)
	local AnimalService = require(ServerScriptService.AnimalService)
	AdminService.AssertAdmin(context.Executor.UserId)
	if not player or not player.Parent then
		return 'That player is not in-game.'
	end
	if type(animalId) ~= 'string' or #animalId < 3 then
		return 'animalId must be a valid Animal Id (e.g. AN_...).'
	end
	if type(amount) ~= 'number' then
		return 'amount must be a number.'
	end
	if amount ~= math.floor(amount) then
		return 'amount must be an integer (no decimals).'
	end
	if amount < 0 then
		return 'amount must be non-negative.'
	end
	if amount ~= amount or amount == math.huge or amount == -math.huge then
		return 'amount must be a valid finite number (not NaN / infinity).'
	end
	-- The authoritative service resolves registry + ownership.
	local result = AnimalService:AddXP(animalId, amount)
	if not result or result.success == false then
		return ('givexp failed: %s (code=%s)'):format(
			tostring(result and result.error or 'unknown'),
			tostring(result and result.code or 'none')
		)
	end
	local newXP = result.newXP
	local newLevel = result.level or 1
	-- Phase 2.7: the grant routed through the canonical AddXP flow,
	-- so the player's XP modifier applied exactly once upstream.
	-- Report requested vs applied so modifier behavior is testable
	-- from chat (1x: identical; active modifier: visibly shaped).
	local requestedXP = result.requestedXP or amount
	local appliedXP = result.appliedXP or amount
	local xpModifier = result.xpModifier or 1
	Debug.Log('CMDR', 'givexp', {
		target = player.UserId,
		animalId = animalId,
		requestedXP = tostring(requestedXP),
		xpModifier = tostring(xpModifier),
		appliedXP = tostring(appliedXP),
		newXP = tostring(newXP),
		newLevel = newLevel,
		levelsGained = result.levelsGained or 0,
		by = context.Executor.UserId,
	})
	-- Phase 2.4: report the progression state. At MaxLevel the
	-- denominator is the bank ceiling (XPRequired(MaxLevel)).
	if result.leveledUp then
		return ('Added %d XP to %s (requested %d x%s = applied %d). Leveled up %d time(s) -> Level %d. Progress: %d/%d XP.'):format(
			appliedXP,
			animalId,
			requestedXP,
			tostring(xpModifier),
			appliedXP,
			result.levelsGained or 0,
			newLevel,
			newXP or 0,
			LevelConfig.GetXPRequired(newLevel)
		)
	end
	return ('Added %d XP to %s (requested %d x%s = applied %d). Level %d, progress %d/%d XP.'):format(
		appliedXP,
		animalId,
		requestedXP,
		tostring(xpModifier),
		appliedXP,
		newLevel,
		newXP or 0,
		LevelConfig.GetXPRequired(newLevel)
	)
end
