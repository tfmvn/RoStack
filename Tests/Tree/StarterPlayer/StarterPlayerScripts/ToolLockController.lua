--!strict
--!native
--[[
	ToolLockController
	==================
	Client mirror of the server-authoritative carry tool lock. While
	the server reports Locked (any CarryRegistry entry: steal, own
	animal/egg pickup — kind/ownership irrelevant), this controller:

	  * hides the default Backpack/hotbar UI,
	  * unequips any equipped Tool immediately,
	  * guards Character.ChildAdded so a Tool equipped mid-lock is
	    unequipped at once (event-driven — no polling loops).

	On unlock it restores the Backpack UI and drops the guard.
	Tools are never destroyed, moved permanently, or reassigned —
	the lock is purely temporary. Server enforcement is independent
	(equip-time unequip at carry start + IsCarrying gates on every
	server-activated Tool), so a tampered client gains nothing.
]]

local Players = game:GetService('Players')
local StarterGui = game:GetService('StarterGui')
local ReplicatedStorage = game:GetService('ReplicatedStorage')

local Debug = require(ReplicatedStorage.Utility.Debug)
local Remotes = require(ReplicatedStorage.Utility.Remotes)

local ToolLockController = {}

local localPlayer = Players.LocalPlayer

local wired = false
local locked = false
local equipGuard: RBXScriptConnection? = nil

local function warnLock(message: string)
	Debug.Warn('ToolLock', message)
end

local function unequipAll()
	if localPlayer == nil then
		return
	end
	pcall(function()
		local character = localPlayer.Character
		local humanoid = if character ~= nil then character:FindFirstChildOfClass('Humanoid') else nil
		if humanoid ~= nil then
			humanoid:UnequipTools()
		end
	end)
end

local function setBackpackEnabled(enabled: boolean)
	pcall(function()
		StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Backpack, enabled)
	end)
end

local function armEquipGuard()
	if equipGuard ~= nil then
		return
	end
	if localPlayer == nil then
		return
	end
	pcall(function()
		local character = localPlayer.Character
		if character == nil then
			return
		end
		equipGuard = character.ChildAdded:Connect(function(child: Instance)
			if locked and child:IsA('Tool') then
				unequipAll()
			end
		end)
	end)
end

local function disarmEquipGuard()
	if equipGuard ~= nil then
		pcall(function()
			(equipGuard :: RBXScriptConnection):Disconnect()
		end)
		equipGuard = nil
	end
end

local function applyLock(isLocked: boolean)
	locked = isLocked
	if isLocked then
		setBackpackEnabled(false)
		unequipAll()
		armEquipGuard()
	else
		disarmEquipGuard()
		setBackpackEnabled(true)
	end
end

function ToolLockController.Init()
	if wired then
		return
	end
	wired = true
	if localPlayer == nil then
		warnLock('no LocalPlayer; controller disabled')
		return
	end
	local folder = Remotes.WaitForReady()
	local ok, event = pcall(function()
		return folder:WaitForChild(Remotes.Names.CarryLock, 10)
	end)
	if ok and event ~= nil and (event :: Instance):IsA('RemoteEvent') then
		pcall(function()
			(event :: RemoteEvent).OnClientEvent:Connect(function(payload: any)
				if type(payload) == 'table' and type(payload.Locked) == 'boolean' then
					applyLock(payload.Locked)
				end
			end)
		end)
	else
		warnLock('CarryLock remote missing; tool lock disabled')
	end
	pcall(function()
		-- Re-arm the equip guard across respawns when locked; a
		-- fresh character otherwise arrives unguarded.
		localPlayer.CharacterAdded:Connect(function(character: Model)
			if locked then
				disarmEquipGuard()
				pcall(function()
					equipGuard = character.ChildAdded:Connect(function(child: Instance)
						if locked and child:IsA('Tool') then
							unequipAll()
						end
					end)
				end)
			end
		end)
		localPlayer.CharacterRemoving:Connect(function()
			disarmEquipGuard()
		end)
	end)
end

-- TEST-ONLY seams (headless-verifiable without remotes).
function ToolLockController._TestIsLocked(): boolean
	return locked
end

return table.freeze(ToolLockController)
