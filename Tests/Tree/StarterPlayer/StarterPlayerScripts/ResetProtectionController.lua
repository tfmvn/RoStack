--!strict
--!native
--[[
	ResetProtectionController
	=========================
	Client-side PRESENTATION for the server-authoritative reset
	gate (see ServerScriptService/Carry/ResetProtectionService).

	The server decides protection from the live CarryRegistry and
	pushes S->C `ResetProtection { Protected, Reason }` on change
	only. This controller applies it to the actual reset UI via
	the supported mechanism:

	  protected   -> StarterGui:SetCore("ResetButtonCallback", false)
	                 (reset button greyed out, reset impossible)
	  unprotected -> StarterGui:SetCore("ResetButtonCallback", true)
	                 (default reset behavior restored)

	SetCore must be pcall-retried: the CoreScripts register
	ResetButtonCallback at an unpredictable time, and calling too
	early throws. The retry loop only waits for API readiness —
	it never polls game state.

	Trust model: this is UX, not authority. A bypassed client can
	still destroy its Character; the server's existing
	carry/steal recovery (Died / Destroying / PlayerRemoving)
	resolves the transaction either way. After respawn the server
	re-syncs (CharacterAdded -> Refresh), so a stale disabled
	button can never survive into a fresh Character.
]]

local StarterGui = game:GetService('StarterGui')
local ReplicatedStorage = game:GetService('ReplicatedStorage')

local Remotes = require(ReplicatedStorage.Utility.Remotes)

local ResetProtectionController = {}

local protected = false
local applied = false -- last value successfully applied via SetCore
local applying = false -- a retry loop is already running

-- Apply one gate value. Retries until the CoreScripts accept it
-- (single-flight: concurrent transitions collapse into the
-- latest `protected` value — no timer, no stale write).
local function applyGate()
	if applying then
		return
	end
	applying = true
	task.spawn(function()
		while true do
			local want = protected
			local ok = pcall(function()
				-- false greys out the reset button; true
				-- restores the default reset behavior.
				StarterGui:SetCore('ResetButtonCallback', not want)
			end)
			if ok then
				-- Re-check: a transition that landed mid-call
				-- must not leave a stale value applied.
				if want == protected then
					applied = want
					break
				end
			end
			task.wait()
		end
		applying = false
		-- A transition that arrived while we were applying is
		-- picked up now (single extra pass, still event-driven).
		if applied ~= protected then
			applyGate()
		end
	end)
end

local function onProtectionPush(payload: any)
	local nextProtected = false
	if type(payload) == 'table' and payload.Protected == true then
		nextProtected = true
	end
	if nextProtected == protected then
		return
	end
	protected = nextProtected
	applyGate()
end

function ResetProtectionController.Init()
	local signal = Remotes.OnClientEvent(Remotes.Names.ResetProtection)
	signal:Connect(onProtectionPush)
end

-- TEST-ONLY seam (Studio specs drive the gating logic without
-- CoreGui): returns the last locally-known protected value.
function ResetProtectionController._TestIsProtected(): boolean
	return protected
end

return table.freeze(ResetProtectionController)
