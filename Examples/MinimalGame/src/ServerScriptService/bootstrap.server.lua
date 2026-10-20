--!strict
--!native
--[[
	MinimalGame bootstrap
	======================
	A deliberately SMALL version of the source game's
	`ServerScriptService/bootstrap.server.lua`, wiring only:

	  EconomyService  +  PlayerService

	That is the smallest useful subset of the library: a player joins, a
	profile loads and persists, and the wallet holds a BigNumber decimal
	string.

	Everything else the source game wires (bases, eggs, animals, arena,
	shops, …) is omitted on purpose. Compare this file against
	`Systems/SharedUtilities/Source/ServerScriptService/bootstrap.server.lua`
	to see what adding a system actually costs.

	Ordering rules that ARE enforced here:
	  1. createRemotes() runs before any service Init().
	  2. EconomyService.Init() runs before PlayerService.Init().
	  3. EconomyService.SetPlayerService(PlayerService) runs before
	     PlayerService.Init() -- the economy must own the money field
	     before the profile loads.
]]

local Players = game:GetService('Players')
local ReplicatedStorage = game:GetService('ReplicatedStorage')

local Remotes = require(ReplicatedStorage.Utility.Remotes)
local DebugConfig = require(ReplicatedStorage.Config.Systems.Debug)
local Debug = require(ReplicatedStorage.Utility.Debug)

local EconomyService = require(script.Parent.EconomyService)
local PlayerService = require(script.Parent.PlayerService)

-- ---------------------------------------------------------------------------
-- Debug wiring
-- ---------------------------------------------------------------------------
-- Config/Systems/Debug.lua is the single source of truth for the debug
-- switches. The Debug module reads its own side's flag (ServerDebug /
-- ClientDebug) plus an optional per-tag whitelist.
Debug.SyncFromDebugConfig(DebugConfig)

-- ---------------------------------------------------------------------------
-- Remotes
-- ---------------------------------------------------------------------------
-- The Remotes module has no creation function -- creating the folder and the
-- RemoteEvents is the bootstrap's job. This is copied from the source game's
-- bootstrap.server.lua:203-222.
local function createRemotes()
	local folder = ReplicatedStorage:FindFirstChild('Remotes')
	if not folder then
		folder = Instance.new('Folder')
		folder.Name = 'Remotes'
		folder.Parent = ReplicatedStorage
	end
	local names = Remotes.Names
	for _, n in pairs(names) do
		if not folder:FindFirstChild(n) then
			local remote = Instance.new('RemoteEvent')
			remote.Name = n
			remote.Parent = folder
		end
	end
	Remotes.SetRemotes(folder)
	return folder
end

createRemotes()

-- ---------------------------------------------------------------------------
-- Services
-- ---------------------------------------------------------------------------
EconomyService.Init()
EconomyService.SetPlayerService(PlayerService)

PlayerService.Init()

-- ---------------------------------------------------------------------------
-- Player lifecycle
-- ---------------------------------------------------------------------------
local function onPlayerAdded(player: Player)
	local ok = PlayerService.LoadPlayerData(player)
	if not ok then
		Debug.Warn('MINIMAL', 'profile load failed; kicking player', {
			userId = tostring(player.UserId),
		})
		player:Kick('Could not load your save. Please rejoin.')
		return
	end

	PlayerService.MarkLoaded(player.UserId)
	PlayerService.PushState(player)
end

local function onPlayerRemoving(player: Player)
	PlayerService.CleanupPlayer(player.UserId)
end

Players.PlayerAdded:Connect(onPlayerAdded)
Players.PlayerRemoving:Connect(onPlayerRemoving)

-- Studio: a player who is already in the place when the script starts.
for _, player in Players:GetPlayers() do
	task.spawn(onPlayerAdded, player)
end

Debug.Log('MINIMAL', 'bootstrap complete')
