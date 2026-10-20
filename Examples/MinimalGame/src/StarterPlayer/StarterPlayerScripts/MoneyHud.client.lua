--!strict
--[[
	MinimalGame client HUD
	=======================
	Shows the player's wallet, pushed by the server on the `PlayerState`
	remote.

	This is deliberately hand-written and tiny. The source game's real client
	layer is 35 scripts under `Systems/ClientPresentation/` -- read that
	system's README for how it is structured, and use it as the model when
	you build a real UI.

	The one rule this file demonstrates: the client does not compute
	anything. It listens for a server push and renders it.
]]

local Players = game:GetService('Players')
local ReplicatedStorage = game:GetService('ReplicatedStorage')
local RunService = game:GetService('RunService')

local player = Players.LocalPlayer
local playerGui = player:WaitForChild('PlayerGui')

-- Build the HUD from code so this example needs no Studio-authored GUI.
local screen = Instance.new('ScreenGui')
screen.Name = 'MinimalMoneyHud'
screen.ResetOnSpawn = false
screen.IgnoreGuiInset = true
screen.Parent = playerGui

local label = Instance.new('TextLabel')
label.Name = 'MoneyLabel'
label.AnchorPoint = Vector2.new(0, 0)
label.Position = UDim2.fromOffset(24, 24)
label.Size = UDim2.fromOffset(360, 44)
label.BackgroundColor3 = Color3.fromRGB(20, 20, 24)
label.BackgroundTransparency = 0.15
label.TextColor3 = Color3.fromRGB(255, 226, 120)
label.TextSize = 26
label.Font = Enum.Font.GothamBold
label.Text = '$0'
label.Parent = screen

local corner = Instance.new('UICorner')
corner.CornerRadius = UDim.new(0, 8)
corner.Parent = label

-- The remote registry is the single source of truth for remote names.
-- Wait for the server to populate the folder before using it.
local Remotes = require(ReplicatedStorage.Utility.Remotes)
local remotesFolder = Remotes.WaitForReady()

local playerState = remotesFolder:WaitForChild('PlayerState')
local pending: { [string]: any }? = nil

local function render()
	if not pending then
		label.Text = 'loading...'
		return
	end
	-- Money is a BigNumber decimal STRING. Displaying it directly is
	-- correct -- never parse it into a Lua number.
	label.Text = '$' .. tostring(pending.Money or '0')
end

playerState.OnClientEvent:Connect(function(payload)
	pending = payload
	render()
end)

-- A local heartbeat is only here so the label re-renders if the push
-- arrives before the listener is attached.
task.spawn(function()
	while RunService and playerGui.Parent do
		task.wait(1)
		render()
	end
end)

render()
