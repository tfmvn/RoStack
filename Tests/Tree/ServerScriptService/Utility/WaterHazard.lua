--!strict
--!native
--[[
	Utility.WaterHazard
	=====================
	Instant-death water: anything with a Humanoid that touches
	`Workspace.Water` dies immediately (Health = 0).

	Server-side and authoritative (aTouched handler cannot be
	spoofed into sparing anyone — the server decides death).
	No config, no remotes, no state: one Touched connection per
	part, connected once at boot.

	`Workspace.Water` is a Studio-authored instance, so this
	resolves defensively: a BasePart gets one connection; a
	Model/Folder gets one per descendant BasePart; a missing
	node warns once and retries via ChildAdded (late-added
	Water still wires up instead of silently staying safe).
]]

local Workspace = game:GetService('Workspace')

local Debug = require(game:GetService('ReplicatedStorage').Utility.Debug)

local WaterHazard = {}

local _wired = false

local function _killOnTouch(part: BasePart)
	pcall(function()
		(part :: BasePart).Touched:Connect(function(hit: Instance)
			local character = hit.Parent
			local humanoid = character and character:FindFirstChildOfClass('Humanoid')
			if humanoid then
				(humanoid :: Humanoid).Health = 0
			end
		end)
	end)
end

local function _wire(node: Instance)
	if node:IsA('BasePart') then
		_killOnTouch(node)
	else
		for _, desc in ipairs(node:GetDescendants()) do
			if desc:IsA('BasePart') then
				_killOnTouch(desc)
			end
		end
	end
end

function WaterHazard.Init()
	if _wired then
		return
	end
	_wired = true
	local water = Workspace:FindFirstChild('Water')
	if water ~= nil then
		_wire(water)
		Debug.Log('Water', 'hazard wired', { node = water:GetFullName() })
	else
		Debug.Warn('Water', 'Workspace.Water missing; hazard inactive (retrying on ChildAdded)', {})
	end
	pcall(function()
		Workspace.ChildAdded:Connect(function(child: Instance)
			if child.Name == 'Water' then
				_wire(child)
				Debug.Log('Water', 'hazard wired (late)', { node = child:GetFullName() })
			end
		end)
	end)
end

return table.freeze(WaterHazard)
