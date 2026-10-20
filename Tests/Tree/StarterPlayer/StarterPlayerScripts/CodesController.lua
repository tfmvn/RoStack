--!strict
--!native
--[[
	CodesController
	===============
	Client owner of the authored `PlayerGui.Main.Codes` CONTENT
	(code TextBox + Continue submit). Open/close ownership lives
	in CodesTopbar.client.lua (the fast-boot TopbarPlus icon) —
	this controller never shows or hides the panel.

	Server-authoritative: the client sends ONLY the typed string
	(CodesAction { Action = 'Redeem', Code }) and uses CodesResult
	for UI state (clear the TextBox on success, restore Continue).
	Player-facing text + SFX arrive on the existing Notify
	channel; nothing here decides the grant.

	Immediate binding: resolves the authored panel without
	waiting on profile, base, animals, arena, or server data
	(same fast pattern as the Settings fix). While a request is
	in flight, Continue is dimmed (Active = false, never hidden)
	and restored the moment the result lands; a backstop
	restores it if a result is ever lost.
]]

local Players = game:GetService('Players')
local ReplicatedStorage = game:GetService('ReplicatedStorage')

local Debug = require(ReplicatedStorage.Utility.Debug)
local Remotes = require(ReplicatedStorage.Utility.Remotes)

local CodesController = {}

local localPlayer = Players.LocalPlayer

local function logCodes(message: string)
	Debug.Log('CodesClient', message)
end

local function warnCodes(message: string)
	Debug.Warn('CodesClient', message)
end

local wired = false
local actionRemote: RemoteEvent? = nil

local codesGui: GuiObject? = nil
local codeBox: TextBox? = nil
local continueButton: GuiButton? = nil
local submitWired = false
local inFlight = false

local SUBMIT_BACKSTOP_S = 5

local function playerGui(): PlayerGui?
	local ok, gui = pcall(function()
		if localPlayer == nil then
			return nil
		end
		return localPlayer:FindFirstChildOfClass('PlayerGui')
	end)
	if ok and gui ~= nil then
		return gui
	end
	return nil
end

local function setContinueEnabled(enabled: boolean)
	pcall(function()
		if continueButton == nil then
			return
		end
		-- NOTE: bind the cast to a local first — a statement
		-- beginning with `(...)` would otherwise glue onto the
		-- previous line as a call.
		local button = continueButton :: GuiButton
		button.Active = enabled
		button.AutoButtonColor = enabled
	end)
end

-- Authored Codes panel resolution (never built here). Expected:
--   Main.Codes (Frame)
--   ├── Continue (TextButton, submits)
--   ├── CurrentLevel (Frame) → TextBox (code input)
--   └── TopBar → CloseButton (owned by CodesTopbar, ignored here)
-- Tolerates renames: falls back to the first descendant TextBox
-- / a Continue-named GuiButton anywhere under Codes.
local function ensureCodesGui(): boolean
	if codesGui ~= nil and (codesGui :: GuiObject).Parent ~= nil then
		return codeBox ~= nil and continueButton ~= nil
	end
	codesGui = nil
	codeBox = nil
	continueButton = nil
	submitWired = false
	pcall(function()
		local gui = playerGui()
		local main = gui and gui:FindFirstChild('Main') or nil
		local codes = main and (main :: Instance):FindFirstChild('Codes') or nil
		if codes == nil or not (codes :: Instance):IsA('GuiObject') then
			return
		end
		codesGui = codes :: GuiObject
		local current = (codes :: Instance):FindFirstChild('CurrentLevel')
		local box: Instance? = nil
		if current ~= nil then
			box = current:FindFirstChild('TextBox')
		end
		if box == nil then
			box = (codes :: Instance):FindFirstChildWhichIsA('TextBox', true)
		end
		if box ~= nil and (box :: Instance):IsA('TextBox') then
			codeBox = box :: TextBox
		end
		local cont = (codes :: Instance):FindFirstChild('Continue')
		if cont ~= nil and (cont :: Instance):IsA('GuiButton') then
			continueButton = cont :: GuiButton
		end
	end)
	return codeBox ~= nil and continueButton ~= nil
end

local function onSubmit()
	if inFlight then
		return
	end
	if not ensureCodesGui() then
		warnCodes('authored Codes UI missing; cannot submit')
		return
	end
	if actionRemote == nil then
		warnCodes('CodesAction remote missing; cannot submit')
		return
	end
	local text = ''
	pcall(function()
		if codeBox ~= nil then
			local box = codeBox :: TextBox
			text = box.Text
		end
	end)
	if text == '' then
		return
	end
	inFlight = true
	setContinueEnabled(false)
	logCodes('submit')
	pcall(function()
		local remote = actionRemote :: RemoteEvent
		remote:FireServer({ Action = 'Redeem', Code = text })
	end)
	-- Self-heal backstop: a lost result must never wedge
	-- Continue. The authoritative CodesResult clears the flight
	-- first (same pattern as the Arena start button).
	task.delay(SUBMIT_BACKSTOP_S, function()
		if inFlight then
			inFlight = false
			setContinueEnabled(true)
		end
	end)
end

local function wireSubmit()
	if submitWired then
		return
	end
	if continueButton == nil then
		return
	end
	submitWired = true
	pcall(function()
		(continueButton :: GuiButton).Activated:Connect(onSubmit)
	end)
end

local function onResult(payload: any)
	if type(payload) ~= 'table' then
		return
	end
	inFlight = false
	setContinueEnabled(true)
	if (payload :: any).Success == true then
		logCodes('success')
		-- Successful redemption: clear the input for the next
		-- code. Failed input stays for correction.
		pcall(function()
			if codeBox ~= nil then
				local box = codeBox :: TextBox
				box.Text = ''
				box:ReleaseFocus()
			end
		end)
	else
		logCodes(('warning reason=%s'):format(tostring((payload :: any).Reason)))
	end
end

function CodesController.Init()
	if wired then
		return
	end
	wired = true
	if localPlayer == nil then
		warnCodes('no LocalPlayer; controller disabled')
		return
	end
	-- Immediate, independent binding: resolve the authored
	-- panel without waiting on remotes or server data.
	pcall(function()
		if ensureCodesGui() then
			wireSubmit()
			logCodes('UI ready')
		end
	end)
	-- Eager single-shot retry: one bounded wait on OUR panel
	-- only, so Continue is armed even if Main replicates after
	-- startup. Never blocks Init's return.
	task.spawn(function()
		pcall(function()
			local gui = playerGui()
			if gui == nil then
				return
			end
			local main = gui:WaitForChild('Main', 5)
			if main == nil then
				return
			end
			if (main :: Instance):WaitForChild('Codes', 5) == nil then
				return
			end
			if ensureCodesGui() then
				wireSubmit()
				logCodes('eager UI ready')
			end
		end)
	end)
	-- Re-resolve on every open: a late-replicating TextBox must
	-- be wired the moment the player can touch it.
	pcall(function()
		if codesGui ~= nil then
			(codesGui :: GuiObject):GetPropertyChangedSignal('Visible'):Connect(function()
				if (codesGui :: GuiObject).Visible then
					pcall(function()
						if ensureCodesGui() then
							wireSubmit()
						end
					end)
				end
			end)
		end
	end)
	local folder = Remotes.WaitForReady()
	local okAction, actionEvent = pcall(function()
		return folder:WaitForChild(Remotes.Names.CodesAction, 10)
	end)
	if okAction and actionEvent ~= nil and (actionEvent :: Instance):IsA('RemoteEvent') then
		actionRemote = actionEvent :: RemoteEvent
	else
		warnCodes('CodesAction remote missing; submit disabled')
	end
	local okResult, resultEvent = pcall(function()
		return folder:WaitForChild(Remotes.Names.CodesResult, 10)
	end)
	if okResult and resultEvent ~= nil and (resultEvent :: Instance):IsA('RemoteEvent') then
		(resultEvent :: RemoteEvent).OnClientEvent:Connect(onResult)
	else
		warnCodes('CodesResult remote missing; submit feedback disabled')
	end
	logCodes('controller ready')
end

return table.freeze(CodesController)
