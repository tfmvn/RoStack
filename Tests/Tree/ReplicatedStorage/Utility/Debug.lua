--!strict
--[[
	Debug
	=====
	Single source of truth for all debug logging in the project.

	Every Debug.Log / Debug.Warn call is filtered through the
	independent client/server switches from Systems.Debug
	(`ServerDebug` / `ClientDebug`) plus an optional per-tag
	whitelist. Flip the flags in ONE place (the canonical
	DebugConfig) to turn diagnostic output on or off per side;
	no need to add or remove prints scattered across modules.

	Side detection is owned HERE (RunService), never by callers:
	server scripts obey ServerDebug only, client scripts obey
	ClientDebug only.

	Usage:
		require(ReplicatedStorage.Utility.Debug)
		Debug.Log('Tag', 'message', optionalTable)

	Output goes to the standard Roblox `print` / `warn` so it shows
	up in the Studio Output window and in the server console. Each
	line is prefixed with [Tag] so the stream is greppable.

	When the side's switch is false, every Debug.* call is a
	couple of boolean checks, then returns — no allocation, no
	string concat, no hidden cost. Keep the call sites verbose;
	the runtime is not.

	Analytics note: this module gates DIAGNOSTIC output only.
	Gameplay/analytics execution (e.g. FunnelService sends) never
	flows through here and is unaffected by these switches.
]]

local RunService = game:GetService('RunService')

local Debug = {}

-- --- Side detection + switches ------------------------------------

-- Evaluated once at require time. Server Scripts see IsServer()
-- true; client LocalScripts see IsClient() true. (Studio Play
-- Solo runs the two sides in separate contexts, so this holds
-- there too.) Callers never branch on side themselves.
local IS_CLIENT = RunService:IsClient()

-- Mirrors of the canonical flags. Default false/false = silent
-- until a bootstrap syncs the config (server bootstrap syncs
-- for the server; client bootstrap syncs for the client).
local ServerDebugEnabled = false
local ClientDebugEnabled = false

-- Optional per-tag whitelist. When non-empty, only tags in this
-- set are printed. When empty, every enabled tag is printed.
-- Example: Debug.AllowedTags = { LB = true, BS = true }
local AllowedTags: { [string]: boolean } = {}

-- --- API ---------------------------------------------------------

-- Canonical sync from Systems.Debug. Each bootstrap calls this on
-- its own side; it is the single source of truth (the legacy
-- GameConfig mirror is deleted). Missing flags fail QUIET
-- (silent), never loud: an absent switch must not enable noise.
function Debug.SyncFromDebugConfig(debugConfig: { [string]: any })
	if type(debugConfig) ~= 'table' then
		return
	end
	if debugConfig.ServerDebug ~= nil then
		ServerDebugEnabled = debugConfig.ServerDebug and true or false
	end
	if debugConfig.ClientDebug ~= nil then
		ClientDebugEnabled = debugConfig.ClientDebug and true or false
	end
	if type(debugConfig.Tags) == 'table' then
		AllowedTags = debugConfig.Tags
	end
	if debugConfig.DrawPaths ~= nil then
		Debug.DrawPaths = debugConfig.DrawPaths and true or false
	end
end

-- True for unit-test and Studio command-bar contexts that need
-- to force output without touching the config. Applies to the
-- CURRENT side only (same rule as the flags).
function Debug.SetEnabled(enabled: boolean)
	if IS_CLIENT then
		ClientDebugEnabled = enabled and true or false
	else
		ServerDebugEnabled = enabled and true or false
	end
end

function Debug.IsEnabled(tag: string?): boolean
	if IS_CLIENT then
		if not ClientDebugEnabled then
			return false
		end
	else
		if not ServerDebugEnabled then
			return false
		end
	end
	if tag and next(AllowedTags) ~= nil then
		return AllowedTags[tag] == true
	end
	return true
end

-- Diagnostic output must NEVER throw into gameplay: a malformed
-- debug call (non-string message, non-table data) degrades to a
-- safe rendering instead of erroring. Debug stays silent unless
-- the side's switch is on, and loud-never-fatal when it is.
local function _safeMessage(message: any): string
	if type(message) == 'string' then
		return message
	end
	local ok, text = pcall(tostring, message)
	if ok and type(text) == 'string' then
		return text
	end
	return '<unprintable>'
end

local function _safeData(data: any): { [string]: any }?
	if type(data) ~= 'table' then
		return nil
	end
	return data
end

function Debug.Log(tag: string, message: string, data: { [string]: any }?)
	if not Debug.IsEnabled(tag) then
		return
	end
	local text = _safeMessage(message)
	local fields = _safeData(data)
	if fields ~= nil then
		-- Stringify the table. We don't use HttpService:JSONEncode
		-- to keep this dependency-free; cheap tostring works for
		-- the kind of state we log (CFrames, enums, primitives).
		local parts = { '[' .. tag .. '] ' .. text .. ' ' }
		local first = true
		for k, v in pairs(fields) do
			if not first then
				table.insert(parts, ', ')
			end
			first = false
			table.insert(parts, tostring(k) .. '=' .. tostring(v))
		end
		print(table.concat(parts))
	else
		print('[' .. tag .. '] ' .. text)
	end
end

function Debug.Warn(tag: string, message: string, data: { [string]: any }?)
	if not Debug.IsEnabled(tag) then
		return
	end
	local text = _safeMessage(message)
	local fields = _safeData(data)
	if fields ~= nil then
		local parts = { '[' .. tag .. '] WARN ' .. text .. ' ' }
		local first = true
		for k, v in pairs(fields) do
			if not first then
				table.insert(parts, ', ')
			end
			first = false
			table.insert(parts, tostring(k) .. '=' .. tostring(v))
		end
		warn(table.concat(parts))
	else
		warn('[' .. tag .. '] ' .. text)
	end
end

-- Convenience: log the start of a public function entry.
function Debug.Enter(tag: string, fnName: string, args: { [string]: any }?)
	if not Debug.IsEnabled(tag) then
		return
	end
	Debug.Log(tag, '> ' .. fnName, args)
end

-- Convenience: log the end of a public function.
function Debug.Exit(tag: string, fnName: string, result: { [string]: any }?)
	if not Debug.IsEnabled(tag) then
		return
	end
	Debug.Log(tag, '< ' .. fnName, result)
end

-- --- World-space path visualization ------------------------------
--
-- When Debug.DrawPaths is true, the pathfinder draws each computed
-- path as a series of small Parts in the world so a developer can
-- see exactly where the pathfinder is routing the model. This is
-- invaluable for diagnosing stuck-walker bugs (a walker that
-- keeps recomputing and never arrives usually has a path that
-- overshoots the target or routes into a wall).
--
-- Drawings are cleared when DrawPaths is toggled off, or when
-- ClearPaths() is called explicitly.
Debug.DrawPaths = false
local _pathFolder: Folder? = nil
local _pathCounter = 0

local function _ensureFolder(): Folder
	if _pathFolder and _pathFolder.Parent then
		return _pathFolder
	end
	local f = Instance.new('Folder')
	f.Name = 'DebugPaths'
	f.Parent = workspace
	_pathFolder = f
	return f
end

-- Draw a path's waypoints as small neon parts. `color` is a Color3.
-- `lifetime` is in seconds; 0 means persistent until ClearPaths.
function Debug.DrawPath(waypoints: { any }, color: Color3?, lifetime: number?)
	if not Debug.DrawPaths then
		return
	end
	local folder = _ensureFolder()
	local c = color or Color3.fromRGB(0, 255, 128)
	for i, wp in ipairs(waypoints) do
		local pos = wp.Position
		local part = Instance.new('Part')
		_pathCounter = _pathCounter + 1
		part.Name = 'PathWP_' .. tostring(_pathCounter) .. '_' .. tostring(i)
		part.Size = Vector3.new(0.4, 0.4, 0.4)
		part.Position = pos + Vector3.new(0, 0.25, 0)
		part.Anchored = true
		part.CanCollide = false
		part.Material = Enum.Material.Neon
		part.Color = c
		part.Parent = folder
		if lifetime and lifetime > 0 then
			task.delay(lifetime, function()
				if part.Parent then
					part:Destroy()
				end
			end)
		end
	end
end

-- Draw a line between two points as a thin Part. Useful for
-- connecting waypoints in path visualizations.
function Debug.DrawLine(a: Vector3, b: Vector3, color: Color3?, lifetime: number?)
	if not Debug.DrawPaths then
		return
	end
	local folder = _ensureFolder()
	local c = color or Color3.fromRGB(0, 255, 128)
	local mid = (a + b) / 2
	local dist = (b - a).Magnitude
	if dist < 0.01 then
		return
	end
	local part = Instance.new('Part')
	_pathCounter = _pathCounter + 1
	part.Name = 'PathLine_' .. tostring(_pathCounter)
	part.Size = Vector3.new(0.1, 0.1, dist)
	part.CFrame = CFrame.lookAt(mid, b)
	part.Anchored = true
	part.CanCollide = false
	part.Material = Enum.Material.Neon
	part.Color = c
	part.Parent = folder
	if lifetime and lifetime > 0 then
		task.delay(lifetime, function()
			if part.Parent then
				part:Destroy()
			end
		end)
	end
end

-- Wipe all drawn paths.
function Debug.ClearPaths()
	if _pathFolder then
		_pathFolder:ClearAllChildren()
	end
end

return Debug
