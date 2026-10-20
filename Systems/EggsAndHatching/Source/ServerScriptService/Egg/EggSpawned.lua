--!strict
--!native
--[[
	Egg.EggSpawned
	==============
	The ONE canonical successful center-egg spawn event. Fired
	by SpawnService._spawnCenter after the model is parented,
	the record is live, and ambient owns it — i.e. only when a
	NEW egg actually enters the world (Automatic/Admin/Test
	origins). Persistence restores and model rebuilds never
	fire: a rejoin is not a spawn.

	Payload: { uniqueId: string, rarity: string, origin: string }.

	Exactly one fire per egg. Listeners (rare-egg notifier,
	future systems) must be fast, non-yielding, and never
	throw — a throwing listener is disconnected, never
	retried, and the spawn itself is unaffected.
]]

local Signals = require(script.Parent.Parent.Parent.ReplicatedStorage.Utility.Signals)

local EggSpawned = {}

local _signal = (Signals :: any).new()

function EggSpawned.Connect(fn: (any) -> ()): RBXScriptConnection?
	local conn: RBXScriptConnection? = nil
	pcall(function()
		conn = (_signal :: any):Connect(fn) :: RBXScriptConnection
	end)
	return conn
end

function EggSpawned.Fire(info: any)
	(_signal :: any):Fire(info)
end

return table.freeze(EggSpawned)
