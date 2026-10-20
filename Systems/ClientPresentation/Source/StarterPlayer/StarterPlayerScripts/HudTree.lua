--!strict
--[[
	HudTree
	=======
	Single source of truth for resolving the Studio-authored HUD
	hierarchy. The live tree nests elements under section frames:

		HUD.BottomLeft.MoneyCounter(.Text)
		HUD.BottomLeft.ServerLuckCounter(.Text)
		HUD.Left.RebirthButton / HUD.Left.ShopButton
		HUD.Top.Tutorial(.Counter / .Steps)
		HUD.Center.Notification
		HUD.Bottom.WaveCounter(.Counter)

	Older Studio versions may still carry the FLAT layout
	(HUD.MoneyCounter, HUD.ShopButton, HUD.Tutorial, ...), so
	every finder tries the nested path first and falls back to
	the legacy flat path. Controllers must resolve through here
	instead of hardcoding FindFirstChild chains, so a Studio
	restructure is a one-file change. Presentation-only: never
	creates, moves, or destroys UI. Never throws (pcall-guarded,
	nil when absent).
]]

local HudTree = {}

-- Descend direct children along `path` from `root`. Nil-safe.
function HudTree.Descend(root: Instance?, ...: string): Instance?
	local node: any = root
	if typeof(node) ~= 'Instance' then
		return nil
	end
	for _, name in ipairs({ ... }) do
		local ok, child = pcall(function()
			return (node :: Instance):FindFirstChild(name)
		end)
		if not ok or child == nil then
			return nil
		end
		node = child
	end
	return node :: Instance
end

function HudTree.Hud(playerGui: Instance?): Instance?
	if typeof(playerGui) ~= 'Instance' then
		return nil
	end
	local hud: Instance? = nil
	pcall(function()
		hud = (playerGui :: Instance):FindFirstChild('HUD')
	end)
	return hud
end

local function _isTextWriter(obj: Instance): boolean
	return obj:IsA('TextLabel') or obj:IsA('TextButton') or obj:IsA('TextBox')
end

-- Resolve a label-ish node to a writable TextLabel: the node
-- itself when it is one, else a direct 'Text' child, else the
-- first text descendant. Nil when nothing suitable exists.
function HudTree.Text(node: Instance?): TextLabel?
	local found: TextLabel? = nil
	pcall(function()
		if typeof(node) ~= 'Instance' then
			return
		end
		if (node :: Instance):IsA('TextLabel') then
			found = node :: TextLabel
			return
		end
		local direct = (node :: Instance):FindFirstChild('Text')
		if direct ~= nil and _isTextWriter(direct) and (direct :: Instance):IsA('TextLabel') then
			found = direct :: TextLabel
			return
		end
		local deep = (node :: Instance):FindFirstChildWhichIsA('TextLabel', true)
		if deep ~= nil then
			found = deep :: TextLabel
		end
	end)
	return found
end

function HudTree.Button(node: Instance?): GuiButton?
	local found: GuiButton? = nil
	pcall(function()
		if typeof(node) ~= 'Instance' then
			return
		end
		if (node :: Instance):IsA('GuiButton') then
			found = node :: GuiButton
			return
		end
		local deep = (node :: Instance):FindFirstChildWhichIsA('GuiButton', true)
		if deep ~= nil then
			found = deep :: GuiButton
		end
	end)
	return found
end

-- Money: HUD.BottomLeft.MoneyCounter(.Text), fallback HUD.MoneyCounter.
function HudTree.MoneyText(playerGui: Instance?): TextLabel?
	local hud = HudTree.Hud(playerGui)
	if hud == nil then
		return nil
	end
	return HudTree.Text(HudTree.Descend(hud, 'BottomLeft', 'MoneyCounter'))
		or HudTree.Text(HudTree.Descend(hud, 'MoneyCounter'))
end

-- Server luck: HUD.BottomLeft.ServerLuckCounter(.Text),
-- fallbacks HUD.ServerLuckCounter, HUD.ServerLuck.
function HudTree.LuckText(playerGui: Instance?): TextLabel?
	local hud = HudTree.Hud(playerGui)
	if hud == nil then
		return nil
	end
	return HudTree.Text(HudTree.Descend(hud, 'BottomLeft', 'ServerLuckCounter'))
		or HudTree.Text(HudTree.Descend(hud, 'ServerLuckCounter'))
		or HudTree.Text(HudTree.Descend(hud, 'ServerLuck'))
end

-- HUD.Left.RebirthButton, fallback HUD.RebirthButton.
function HudTree.RebirthButton(playerGui: Instance?): GuiButton?
	local hud = HudTree.Hud(playerGui)
	if hud == nil then
		return nil
	end
	return HudTree.Button(HudTree.Descend(hud, 'Left', 'RebirthButton'))
		or HudTree.Button(HudTree.Descend(hud, 'RebirthButton'))
end

-- HUD.Left.ShopButton, fallback HUD.ShopButton.
function HudTree.ShopButton(playerGui: Instance?): GuiButton?
	local hud = HudTree.Hud(playerGui)
	if hud == nil then
		return nil
	end
	return HudTree.Button(HudTree.Descend(hud, 'Left', 'ShopButton'))
		or HudTree.Button(HudTree.Descend(hud, 'ShopButton'))
end

-- Tutorial root: HUD.Top.Tutorial (container with Counter +
-- Steps), fallbacks HUD.TutorialSteps, HUD.Tutorial.
function HudTree.TutorialRoot(playerGui: Instance?): Instance?
	local hud = HudTree.Hud(playerGui)
	if hud == nil then
		return nil
	end
	return HudTree.Descend(hud, 'Top', 'Tutorial')
		or HudTree.Descend(hud, 'TutorialSteps')
		or HudTree.Descend(hud, 'Tutorial')
end

-- Tutorial.Counter label under the new root. Nil on legacy trees.
function HudTree.TutorialCounter(playerGui: Instance?): TextLabel?
	local hud = HudTree.Hud(playerGui)
	if hud == nil then
		return nil
	end
	return HudTree.Text(HudTree.Descend(hud, 'Top', 'Tutorial', 'Counter'))
end

-- Tutorial.Steps single-instruction label under the new root.
function HudTree.TutorialSteps(playerGui: Instance?): TextLabel?
	local hud = HudTree.Hud(playerGui)
	if hud == nil then
		return nil
	end
	return HudTree.Text(HudTree.Descend(hud, 'Top', 'Tutorial', 'Steps'))
end

-- Notification: HUD.Center.Notifications (plural, canonical),
-- then HUD.Center.Notification (singular legacy), then the
-- legacy HUD.Notifications panel. Nothing is ever created.
function HudTree.NotificationPanel(playerGui: Instance?): GuiObject?
	local hud = HudTree.Hud(playerGui)
	if hud == nil then
		return nil
	end
	local found: GuiObject? = nil
	pcall(function()
		local node = HudTree.Descend(hud, 'Center', 'Notifications')
		if node ~= nil and (node :: Instance):IsA('GuiObject') then
			found = node :: GuiObject
			return
		end
		local single = HudTree.Descend(hud, 'Center', 'Notification')
		if single ~= nil and (single :: Instance):IsA('GuiObject') then
			found = single :: GuiObject
			return
		end
		local legacy = HudTree.Descend(hud, 'Notifications')
		if legacy ~= nil and (legacy :: Instance):IsA('GuiObject') then
			found = legacy :: GuiObject
		end
	end)
	return found
end

-- WaveCounter root: HUD.Bottom.WaveCounter, fallback HUD.WaveCounter.
-- The live number goes on its Counter child (or itself when it
-- is a label).
function HudTree.WaveRoot(playerGui: Instance?): Instance?
	local hud = HudTree.Hud(playerGui)
	if hud == nil then
		return nil
	end
	return HudTree.Descend(hud, 'Bottom', 'WaveCounter') or HudTree.Descend(hud, 'WaveCounter')
end

function HudTree.WaveCounter(playerGui: Instance?): TextLabel?
	local root = HudTree.WaveRoot(playerGui)
	if root == nil then
		return nil
	end
	return HudTree.Text(HudTree.Descend(root, 'Counter')) or HudTree.Text(root)
end

-- --- Ancestor-chain visibility ownership -------------------------------
-- A leaf is only on-screen when its whole chain is visible
-- (ScreenGui.Enabled + every GuiObject ancestor + itself), so
-- each feature ensures its chain when active. Flips are tracked:
-- only ancestors THIS module turned on are ever turned back off,
-- and only once they hold no other visible GuiObject child
-- (shared sections like Top/Center/Bottom are never stolen from
-- other UI). Call ReleaseChain AFTER hiding your own leaf.

local _flipped: { [GuiObject]: boolean } = {}

local function _chain(node: Instance?): { GuiObject }
	local out: { GuiObject } = {}
	local current: Instance? = node
	while typeof(current) == 'Instance' and (current :: Instance).Name ~= 'PlayerGui' do
		if (current :: Instance):IsA('GuiObject') then
			table.insert(out, current :: GuiObject)
		end
		local parent: Instance? = nil
		pcall(function()
			parent = (current :: Instance).Parent
		end)
		if parent == nil or parent == current then
			break
		end
		current = parent
	end
	return out
end

-- Ensure the full ancestor chain (plus the node itself) is
-- visible/enabled. Records only the objects it flipped, so a
-- later ReleaseChain restores exactly what was borrowed.
-- Returns the flipped count (diagnostic only). Never throws.
function HudTree.EnsureChainVisible(node: Instance?): number
	local flipped = 0
	pcall(function()
		for _, obj in ipairs(_chain(node)) do
			local gui = obj :: GuiObject
			if gui:IsA('ScreenGui') then
				local screen = gui :: ScreenGui
				if screen.Enabled == false then
					screen.Enabled = true
					if _flipped[gui] == nil then
						_flipped[gui] = true
						flipped += 1
					end
				end
			elseif gui.Visible == false then
				gui.Visible = true
				if _flipped[gui] == nil then
					_flipped[gui] = true
					flipped += 1
				end
			end
		end
	end)
	return flipped
end

-- After hiding your own leaf, restore ancestors this module
-- flipped, but ONLY while they hold no other visible GuiObject
-- child (shared parents stay up for whoever still needs them).
-- Never throws.
function HudTree.ReleaseChain(node: Instance?)
	pcall(function()
		for _, obj in ipairs(_chain(node)) do
			local gui = obj :: GuiObject
			if _flipped[gui] ~= true then
				continue
			end
			local otherVisible = false
			for _, child in ipairs(gui:GetChildren()) do
				if child ~= node and child:IsA('GuiObject') and (child :: GuiObject).Visible then
					otherVisible = true
					break
				end
			end
			if not otherVisible then
				if gui:IsA('ScreenGui') then
					(gui :: ScreenGui).Enabled = false
				else
					gui.Visible = false
				end
				_flipped[gui] = nil
			end
		end
	end)
end

return HudTree
