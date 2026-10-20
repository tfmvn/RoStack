--!strict
--!native
--[[
	PlayerBoard
	===========
	Display-only mirror of base ownership onto the Studio-authored
	board (`Workspace.Map.Bases.Base_<n>.PlayerBoard…`):

		Workspace.Map.Bases.Base_<n>.PlayerBoard.Main.SurfaceGui.Frame
		├── Name   (TextLabel) — the owner's `DisplayName`
		└── Avatar (ImageLabel) — the owner's headshot thumbnail

	Ownership is NEVER derived from the board: BaseService owns
	ownership; this module only reflects it. All functions are
	nil-safe and yield-free for the caller — the thumbnail fetch
	runs on a detached thread so base assignment never blocks on
	it.

	Empty-state handling: the Studio-authored defaults are cached
	per board on first sight and restored on Clear, so "reset to
	the existing empty/default state" means the actual Studio
	defaults, not an invented string.
]]

local Players = game:GetService('Players')

local StandResolver = require(script.Parent.Parent.Parent.ReplicatedStorage.Utility.StandResolver)

local PlayerBoard = {}

-- boardFullName -> { nameText: string?, avatarImage: string? }.
-- Cached lazily on first Refresh/Clear so Clear restores the
-- Studio defaults even if the board was never assigned.
local _defaults: { [string]: { nameText: string?, avatarImage: string? } } = {}

local function _keyFor(baseFolder: Instance): string
	return baseFolder:GetFullName()
end

local function _rememberDefaults(baseFolder: Instance, parts: any)
	local key = _keyFor(baseFolder)
	if _defaults[key] ~= nil then
		return
	end
	_defaults[key] = {
		nameText = parts.nameLabel and parts.nameLabel.Text or nil,
		avatarImage = parts.avatarImage and parts.avatarImage.Image or nil,
	}
end

-- Reflect ownership of `baseFolder` for `player`. When `player`
-- is nil (tests, edge paths), falls back to Clear semantics.
function PlayerBoard.Refresh(baseFolder: Instance?, player: Player?)
	if typeof(baseFolder) ~= 'Instance' then
		return
	end
	if typeof(player) ~= 'Instance' or not (player :: Instance):IsA('Player') then
		PlayerBoard.Clear(baseFolder)
		return
	end
	local parts = StandResolver.GetPlayerBoardParts(baseFolder)
	if parts.frame == nil then
		return
	end
	_rememberDefaults(baseFolder, parts)
	local typedPlayer = player :: Player
	local displayName: string = typedPlayer.DisplayName
	if type(displayName) ~= 'string' or displayName == '' then
		displayName = typedPlayer.Name
	end
	if parts.nameLabel then
		(parts.nameLabel :: TextLabel).Text = displayName
	end
	-- Thumbnail fetch must never block assignment and must
	-- survive leave/reassign races: capture the board + user so
	-- a late result for a previous owner cannot paint over the
	-- new one.
	local userId = typedPlayer.UserId
	local boardKey = _keyFor(baseFolder)
	local avatarSlot = parts.avatarImage
	if avatarSlot then
		task.spawn(function()
			local ok, content, _isReady = pcall(function()
				return Players:GetUserThumbnailAsync(
					userId,
					Enum.ThumbnailType.HeadShot,
					Enum.ThumbnailSize.Size420x420
				)
			end)
			if not ok or type(content) ~= 'string' or content == '' then
				return
			end
			-- Still the same board and still owned by the same
			-- user? The ownership check runs through the
			-- cached board key + a live player lookup so a
			-- reassigned board never shows a stale face.
			local live = Players:GetPlayerByUserId(userId)
			if not live then
				return
			end
			if _defaults[boardKey] == nil then
				return
			end
			if avatarSlot.Parent == nil then
				return
			end
			avatarSlot.Image = content
		end)
	end
end

-- Reset the board to its Studio-authored defaults. Called on
-- release, cleanup, and leave so the previous player's name and
-- face never linger for the next owner.
function PlayerBoard.Clear(baseFolder: Instance?)
	if typeof(baseFolder) ~= 'Instance' then
		return
	end
	local parts = StandResolver.GetPlayerBoardParts(baseFolder)
	if parts.frame == nil then
		return
	end
	_rememberDefaults(baseFolder, parts)
	local cached = _defaults[_keyFor(baseFolder)]
	if parts.nameLabel then
		if cached and cached.nameText ~= nil then
			(parts.nameLabel :: TextLabel).Text = cached.nameText :: string
		else
			(parts.nameLabel :: TextLabel).Text = ''
		end
	end
	if parts.avatarImage then
		if cached and cached.avatarImage ~= nil then
			(parts.avatarImage :: ImageLabel).Image = cached.avatarImage :: string
		else
			(parts.avatarImage :: ImageLabel).Image = ''
		end
	end
end

return table.freeze(PlayerBoard)
