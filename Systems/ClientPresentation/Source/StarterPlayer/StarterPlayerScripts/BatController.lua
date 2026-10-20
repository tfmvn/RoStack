--!strict
--!native
--[[
	BatController
	=============
	Client side of Bat PvP: instant local swing feedback only. When a
	configured Bat Tool is equipped, Tool.Activated immediately plays
	the swing animation (rbxassetid://94946857147601) on the local
	character and fires the empty BatSwing request. The server decides
	everything else (validity, cooldown, targets, VFX/SFX, ragdoll,
	knockback, steal cancel) — this controller never claims a hit,
	never touches other players, and never presents confirmed effects
	(those are server-mounted on the target).

	Animation notes: purely cosmetic, plays on swing AND on miss.
	Local input cooldown mirrors BatConfig so spam clicks don't stack
	animations (server cooldown stays authoritative).
]]

local Players = game:GetService('Players')
local ReplicatedStorage = game:GetService('ReplicatedStorage')

local Debug = require(ReplicatedStorage.Utility.Debug)
local Remotes = require(ReplicatedStorage.Utility.Remotes)
local BatConfig = require(ReplicatedStorage.Config.Economy.Gear).Combat

local BatController = {}

local SWING_ANIMATION_ID = 'rbxassetid://79224347193775'

local localPlayer = Players.LocalPlayer

local wired = false
local swingRemote: RemoteEvent? = nil
local lastLocalSwing = 0
local hookedTools: { [Tool]: RBXScriptConnection } = {}
local activeTrack: AnimationTrack? = nil

local function warnBat(message: string)
	Debug.Warn('Bat', message)
end

local function isBatTool(tool: Instance?): boolean
	if tool == nil or not tool:IsA('Tool') then
		return false
	end
	local entry: any = nil
	pcall(function()
		entry = BatConfig.GetByToolName(tool.Name)
	end)
	return entry ~= nil
end

local function stopSwingTrack()
	if activeTrack ~= nil then
		pcall(function()
			(activeTrack :: AnimationTrack):Stop(0.05)
		end)
		activeTrack = nil
	end
end

local function playSwingAnimation()
	if localPlayer == nil then
		return
	end
	local character = localPlayer.Character
	if character == nil then
		return
	end
	local humanoid = character:FindFirstChildOfClass('Humanoid')
	if humanoid == nil then
		return
	end
	local animator = humanoid:FindFirstChildOfClass('Animator')
	if animator == nil then
		return
	end
	stopSwingTrack()
	pcall(function()
		local anim = Instance.new('Animation')
		anim.AnimationId = SWING_ANIMATION_ID
		local track = (animator :: Animator):LoadAnimation(anim)
		track.Priority = Enum.AnimationPriority.Action
		track.Looped = false
		track:Play(0.05)
		activeTrack = track
		pcall(function()
			anim:Destroy()
		end)
	end)
end

local function onActivated(tool: Tool)
	if localPlayer == nil then
		return
	end
	if not isBatTool(tool) then
		return
	end
	-- Local input gate only (server re-validates everything).
	local cooldown = 0.5
	pcall(function()
		local entry = BatConfig.GetByToolName(tool.Name)
		if entry ~= nil then
			cooldown = (entry :: any).SwingCooldown
		end
	end)
	local now = os.clock()
	if now - lastLocalSwing < cooldown then
		return
	end
	lastLocalSwing = now
	-- Instant feedback first, request second — same tick, no waits.
	playSwingAnimation()
	if swingRemote ~= nil then
		pcall(function()
			(swingRemote :: RemoteEvent):FireServer()
		end)
	end
end

local function hookTool(tool: Tool)
	if hookedTools[tool] ~= nil then
		return
	end
	if not isBatTool(tool) then
		return
	end
	pcall(function()
		hookedTools[tool] = tool.Activated:Connect(function()
			onActivated(tool)
		end)
		tool.Destroying:Once(function()
			local conn = hookedTools[tool]
			if conn ~= nil then
				pcall(function()
					conn:Disconnect()
				end)
			end
			hookedTools[tool] = nil
		end)
	end)
end

local function hookCharacter(character: Model)
	pcall(function()
		for _, child in ipairs(character:GetChildren()) do
			if child:IsA('Tool') then
				hookTool(child)
			end
		end
		character.ChildAdded:Connect(function(child: Instance)
			if child:IsA('Tool') then
				hookTool(child)
			end
		end)
	end)
	-- Tools equip into the character; backpack copies need no hooks
	-- (Activated only fires on the equipped instance).
end

function BatController.Init()
	if wired then
		return
	end
	wired = true
	if localPlayer == nil then
		warnBat('no LocalPlayer; controller disabled')
		return
	end
	local folder = Remotes.WaitForReady()
	local ok, event = pcall(function()
		return folder:WaitForChild(Remotes.Names.BatSwing, 10)
	end)
	if ok and event ~= nil and (event :: Instance):IsA('RemoteEvent') then
		swingRemote = event :: RemoteEvent
	else
		warnBat('BatSwing remote missing; swings disabled')
	end
	pcall(function()
		local character = localPlayer.Character
		if character ~= nil then
			hookCharacter(character)
		end
		localPlayer.CharacterAdded:Connect(function(character: Model)
			stopSwingTrack()
			hookCharacter(character)
		end)
		localPlayer.CharacterRemoving:Connect(function()
			stopSwingTrack()
		end)
	end)
end

return table.freeze(BatController)
