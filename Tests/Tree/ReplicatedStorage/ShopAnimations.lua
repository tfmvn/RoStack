--// ShopAnimations (ModuleScript)
--// Put in: ReplicatedStorage > ShopAnimations
--//
--// Usage:
--//   local Anim = require(ReplicatedStorage.ShopAnimations)
--//   Anim.Open(frame, "Pop")
--//   Anim.Close(frame, "Pop", function() print("closed") end)
--//
--// Notes:
--//  * Frame should be a CanvasGroup so fade works on the whole frame + children.
--//    (A normal Frame still works, it just skips the fade part.)
--//  * Frame should have AnchorPoint = (0.5, 0.5) so scale/spin happen from the center.
--//  * The frame's Position/Size when first used is treated as its "resting" state.

local TweenService = game:GetService("TweenService")

local ShopAnimations = {}

local ES, ED = Enum.EasingStyle, Enum.EasingDirection

--// Style definitions -------------------------------------------------------
-- Each style describes the HIDDEN state. Opening tweens hidden -> normal,
-- closing tweens normal -> hidden.
--   Alpha    : GroupTransparency when hidden (1 = invisible)
--   Scale    : UIScale when hidden
--   Rotation : degrees when hidden
--   Offset   : UDim2 added to the resting position when hidden
--   Size     : Vector2 multiplier on width/height when hidden
--   Easing   : EasingStyle for open (CloseEasing optional override for close)
--   Time     : seconds

local Styles = {}
local StyleList = {}

local function def(name, p)
	p.Name = name
	p.Alpha = p.Alpha or 0
	p.Scale = p.Scale or 1
	p.Rotation = p.Rotation or 0
	p.Offset = p.Offset or UDim2.new()
	p.Size = p.Size or Vector2.new(1, 1)
	p.Easing = p.Easing or ES.Quad
	p.Time = p.Time or 0.4
	Styles[name] = p
	table.insert(StyleList, name)
end

def("Fade",        { Alpha = 1, Time = 0.35 })
def("Pop",         { Alpha = 1, Scale = 0, Easing = ES.Back, Time = 0.4 })
def("Elastic",     { Alpha = 1, Scale = 0, Easing = ES.Elastic, CloseEasing = ES.Back, Time = 0.8 })
def("Zoom Out",    { Alpha = 1, Scale = 2, Easing = ES.Quint, Time = 0.45 })
def("Slide Left",  { Offset = UDim2.fromScale(-1, 0), Easing = ES.Quint, Time = 0.5 })
def("Slide Right", { Offset = UDim2.fromScale(1, 0), Easing = ES.Quint, Time = 0.5 })
def("Slide Up",    { Offset = UDim2.fromScale(0, 1), Easing = ES.Quint, Time = 0.5 })
def("Slide Down",  { Offset = UDim2.fromScale(0, -1), Easing = ES.Quint, Time = 0.5 })
def("Bounce Drop", { Offset = UDim2.fromScale(0, -1), Easing = ES.Bounce, CloseEasing = ES.Quad, Time = 0.8 })
def("Spin",        { Alpha = 1, Scale = 0, Rotation = 360, Easing = ES.Quart, Time = 0.6 })
def("Flip",        { Alpha = 1, Size = Vector2.new(0, 1), Easing = ES.Back, Time = 0.5 })
def("Swing",       { Alpha = 1, Rotation = -30, Offset = UDim2.fromScale(0, 0.4), Easing = ES.Back, Time = 0.55 })

ShopAnimations.Styles = StyleList -- ordered list of style names

--// Internals ---------------------------------------------------------------

local BASE = {
	Alpha = 0,
	Scale = 1,
	Rotation = 0,
	Offset = UDim2.new(),
	Size = Vector2.new(1, 1),
}

local frameData = setmetatable({}, { __mode = "k" })

local function getData(frame)
	local data = frameData[frame]
	if data then
		return data
	end

	local uiScale = frame:FindFirstChild("AnimScale")
	if not uiScale then
		uiScale = Instance.new("UIScale")
		uiScale.Name = "AnimScale"
		uiScale.Parent = frame
	end

	data = {
		Pos = frame.Position,
		Size = frame.Size,
		UIScale = uiScale,
		IsGroup = frame:IsA("CanvasGroup"),
		Tweens = {},
		Token = 0,
	}
	frameData[frame] = data
	return data
end

local function sizeFor(data, st)
	local s = data.Size
	return UDim2.new(
		s.X.Scale * st.Size.X, s.X.Offset * st.Size.X,
		s.Y.Scale * st.Size.Y, s.Y.Offset * st.Size.Y
	)
end

local function applyState(frame, data, st)
	frame.Position = data.Pos + st.Offset
	frame.Size = sizeFor(data, st)
	frame.Rotation = st.Rotation
	data.UIScale.Scale = st.Scale
	if data.IsGroup then
		(frame :: CanvasGroup).GroupTransparency = st.Alpha
	end
end

local function cancel(data)
	for _, tw in data.Tweens do
		tw:Cancel()
	end
	table.clear(data.Tweens)
end

local function play(frame, data, target, info, onDone)
	cancel(data)
	data.Token += 1
	local token = data.Token

	local goals = {
		Position = data.Pos + target.Offset,
		Size = sizeFor(data, target),
		Rotation = target.Rotation,
	}
	if data.IsGroup then
		goals.GroupTransparency = target.Alpha
	end

	local main = TweenService:Create(frame, info, goals)
	local scaleTween = TweenService:Create(data.UIScale, info, { Scale = target.Scale })
	data.Tweens = { main, scaleTween }

	main.Completed:Once(function(playbackState)
		if token == data.Token and playbackState == Enum.PlaybackState.Completed and onDone then
			onDone()
		end
	end)

	main:Play()
	scaleTween:Play()
	return main
end

local function getStyle(name)
	local st = Styles[name]
	if not st then
		warn(("[ShopAnimations] Unknown style '%s', using Fade"):format(tostring(name)))
		st = Styles.Fade
	end
	return st
end

--// Public API --------------------------------------------------------------

function ShopAnimations.Open(frame: GuiObject, styleName: string, onDone: (() -> ())?)
	local style = getStyle(styleName)
	local data = getData(frame)

	cancel(data)
	applyState(frame, data, style)
	frame.Visible = true

	local info = TweenInfo.new(style.Time, style.Easing, ED.Out)
	return play(frame, data, BASE, info, onDone)
end

function ShopAnimations.Close(frame: GuiObject, styleName: string, onDone: (() -> ())?)
	local style = getStyle(styleName)
	local data = getData(frame)

	local info = TweenInfo.new(style.Time * 0.8, style.CloseEasing or style.Easing, ED.In)
	return play(frame, data, style, info, function()
		frame.Visible = false
		if onDone then
			onDone()
		end
	end)
end

-- Call this if you resize/move the frame at runtime and want the new
-- Position/Size to become its resting state.
function ShopAnimations.Rebase(frame: GuiObject)
	local data = getData(frame)
	cancel(data)
	data.Pos = frame.Position
	data.Size = frame.Size
end

return ShopAnimations
