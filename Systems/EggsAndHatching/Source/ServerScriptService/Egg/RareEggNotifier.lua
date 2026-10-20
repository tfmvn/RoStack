--!strict
--!native
--[[
	Egg.RareEggNotifier
	====================
	The single listener that turns successful high-rarity egg
	spawns into a server-wide celebration. Watches the
	canonical EggSpawned event; when a spawned egg's rarity is
	Legendary or above, EVERY player in the server gets one
	`RareEgg_Spawned` toast (players who caused the spawn
	included — this is a global event, not a reward).

	Threshold uses the canonical Rarity enum
	(Legendary/Mythic/Divine/Secret), not display order and not
	string matching. One fire per egg by construction: the
	event fires once per successful spawn, and this is the only
	subscriber that notifies. Owns no spawning, no egg state.
]]

local Players = game:GetService('Players')

local Rarity = require(script.Parent.Parent.Parent.ReplicatedStorage.Types.RarityType)
local RarityConfig = require(script.Parent.Parent.Parent.ReplicatedStorage.Config.Creatures.Rarity)
local Debug = require(script.Parent.Parent.Parent.ReplicatedStorage.Utility.Debug)
local NotificationService = require(script.Parent.Parent.Base.NotificationService)
local EggSpawned = require(script.Parent.EggSpawned)

local RareEggNotifier = {}

-- Canonical high-rarity set: Legendary and above. Explicit
-- enum set (not Order-indexed: Order canonically sorts Mythic
-- below Legendary, which would exclude Mythic from an
-- index-based threshold).
local HIGH_RARITY: { [string]: boolean } = {
	[Rarity.Legendary] = true,
	[Rarity.Mythic] = true,
	[Rarity.Divine] = true,
	[Rarity.Secret] = true,
}

local _started = false

-- Pure predicate (test seam): should this rarity celebrate?
function RareEggNotifier.ShouldNotify(rarity: any): boolean
	return type(rarity) == 'string' and HIGH_RARITY[rarity] == true
end

local function _onEggSpawned(info: any)
	pcall(function()
		if type(info) ~= 'table' then
			return
		end
		local rarity = info.rarity
		if not RareEggNotifier.ShouldNotify(rarity) then
			return
		end
		local display = RarityConfig.RarityDisplayName[rarity]
		local eggName = if type(display) == 'string' and display ~= '' then display else tostring(rarity) .. ' Egg'
		Debug.Log('EG', 'rare egg spawned — notifying server', {
			uniqueId = tostring(info.uniqueId),
			rarity = tostring(rarity),
		})
		for _, player in ipairs(Players:GetPlayers()) do
			pcall(NotificationService.NotifySuccess, player, 'RareEgg_Spawned', { EggName = eggName })
		end
	end)
end

-- Idempotent: safe to call from Init paths that may run in
-- tests. Exactly one subscription per server lifetime.
function RareEggNotifier.Start()
	if _started then
		return
	end
	_started = true
	pcall(EggSpawned.Connect, _onEggSpawned)
end

return table.freeze(RareEggNotifier)
