--!strict
--!native
--[[
	getstatsServer
	Server-side Run for /getstats. Loaded by Cmdr's
	Registry:RegisterCommandsIn as commandObject.Run; executes only
	on the server. The shared getstats.lua carries the definition
	(Name/Group/Args) and is replicated to the client, which
	forwards execution here through the Cmdr RemoteFunction.

	Call conventions matter here: Get / GetStats / ListForPlayer are
	dot-defined on AnimalService (plain functions) while
	GetLevel / GetXP are colon-defined — they are invoked with the
	matching syntax below.
]]

local ServerScriptService = game:GetService('ServerScriptService')

local Debug = require(game.ReplicatedStorage.Utility.Debug)
local LevelConfig = require(game.ReplicatedStorage.Config.Creatures.Progression)

-- One line per owned Animal, for the "wrong/unknown Id" replies.
local function listSuffix(playerName: string, entries: { any }): string
	if #entries == 0 then
		return playerName .. ' owns no Animals.'
	end
	local lines = {}
	for _, entry in ipairs(entries) do
		lines[#lines + 1] = ('%s (%s, %s, L%d)'):format(entry.UniqueId, entry.DisplayName, entry.Rarity, entry.Level)
	end
	return playerName .. "'s Animals:\n" .. table.concat(lines, '\n')
end

return function(context, player: Player, animalId: string)
	local AdminService = require(ServerScriptService.Admin.AdminService)
	local AnimalService = require(ServerScriptService.AnimalService)
	AdminService.AssertAdmin(context.Executor.UserId)
	if not player or not player.Parent then
		return 'That player is not in-game.'
	end
	if type(animalId) ~= 'string' or #animalId < 3 then
		return 'animalId must be a valid Animal Id (e.g. AN_...).'
	end

	-- Ownership + metadata from the runtime record (dot call).
	local animal = AnimalService.Get(animalId)
	if not animal then
		return ('Animal %s not found. %s'):format(
			animalId,
			listSuffix(player.Name, AnimalService.ListForPlayer(player.UserId))
		)
	end
	if animal.ownerUserId ~= player.UserId then
		return ('%s exists but belongs to another player (userId %d). %s'):format(
			animalId,
			animal.ownerUserId,
			listSuffix(player.Name, AnimalService.ListForPlayer(player.UserId))
		)
	end

	-- The authoritative Phase 2.5 derived-stat path.
	local stats = AnimalService.GetStats(animalId)
	if not stats then
		return ('Animal %s disappeared between lookup and stat read.'):format(animalId)
	end
	local level = AnimalService:GetLevel(animalId) or animal.Level or 1
	local xp = AnimalService:GetXP(animalId) or 0

	Debug.Log('CMDR', 'getstats', {
		target = player.UserId,
		animalId = animalId,
		level = level,
		xp = xp,
		health = tostring(stats.Health),
		damage = tostring(stats.Damage),
		by = context.Executor.UserId,
	})

	-- At MaxLevel the denominator is the bank ceiling
	-- (XPRequired(MaxLevel)) — same convention as /givexp.
	return ('%s (%s, %s): Level %d, XP %d/%d, Health %.6g, Damage %.6g'):format(
		animalId,
		tostring(animal.displayName),
		tostring(animal.rarity),
		level,
		xp,
		LevelConfig.GetXPRequired(level),
		stats.Health,
		stats.Damage
	)
end
