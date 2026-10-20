--!strict
--!native
--[[
	Tutorial.TutorialSignals
	=========================
	Thin named-event bus between gameplay systems and the
	Tutorial guide layer. Same pattern as Egg.EggSpawned: game
	systems Fire exactly once per committed action; the
	Tutorial subscribes. Gameplay files top-require this leaf
	(it needs only the Signals utility), so no require cycles
	can form in either direction.

	Channels (payload shapes):
	  EggPurchased   { UserId: number, EggId: string }
	  EggPlaced      { EggId: string, OwnerUserId: number?, SlotId: string }
	  EggHatched     { UserId: number, EggId: string, AnimalId: string }
	  AnimalPickedUp { UserId: number, AnimalId: string }
	  AnimalPlaced   { UserId: number, AnimalId: string, SlotId: string }
	  ArenaStarted   { UserId: number }
	  ArenaEnded     { UserId: number }
	  ArenaCancelled { UserId: number }
	  AnimalUpgraded { UserId: number, AnimalId: string, NewLevel: number }
	  BaseLocked     { UserId: number, BaseId: string }

	Fire never throws (a throwing listener is disconnected and
	logged, never retried). Listeners must be fast and
	non-yielding.
]]

local Signals = require(script.Parent.Parent.Parent.ReplicatedStorage.Utility.Signals)
local Debug = require(script.Parent.Parent.Parent.ReplicatedStorage.Utility.Debug)

local TutorialSignals = {}

local _channels: { [string]: any } = {}

local function _channel(name: string): any
	local existing = _channels[name]
	if existing ~= nil then
		return existing
	end
	local created: any = nil
	pcall(function()
		created = (Signals :: any).new()
	end)
	if created ~= nil then
		_channels[name] = created
	end
	return created
end

-- Fire a tutorial channel. Total: never throws, never yields
-- the caller, works when nobody listens.
function TutorialSignals.Fire(name: any, payload: any)
	pcall(function()
		if type(name) ~= 'string' or name == '' then
			return
		end
		local channel = _channel(name)
		if channel ~= nil then
			(channel :: any):Fire(payload)
		end
	end)
end

-- Connect a listener. Returns the connection (or nil when the
-- bus itself is unavailable). Never throws.
function TutorialSignals.Connect(name: any, fn: (any) -> ()): RBXScriptConnection?
	local conn: RBXScriptConnection? = nil
	pcall(function()
		if type(name) ~= 'string' or name == '' then
			return
		end
		if type(fn) ~= 'function' then
			return
		end
		local channel = _channel(name)
		if channel ~= nil then
			conn = (channel :: any):Connect(fn)
		end
	end)
	return conn
end

-- TEST seam: drop all channels so specs observe fresh.
function TutorialSignals._TestReset()
	table.clear(_channels)
	Debug.Log('TS', 'channels reset', {})
end

return table.freeze(TutorialSignals)
