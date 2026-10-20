--!strict
--!native
--[[
	AdminService
	============
	The single source of truth for "is this userId an admin and
	at what rank". Every Cmdr command calls one of the AssertX
	functions as its first line; no Cmdr command is gated on a
	per-command string check, no command bypasses this module.

	Why a separate service:
	  * The Cmdr 1.12.0 filter callback receives only the command
	    object, not the calling player. So Cmdr's group-based
	    permission cannot filter per-player at registration time.
	    The actual gate must be `AdminService.AssertX(playerId)`
	    inside each Run function. Centralizing the gate means
	    "is admin" is one answer to one question; there is no
	    second opinion.
	  * Adding a new admin at runtime (via /addadmin) is a single
	    table mutation that all current and future commands pick
	    up immediately. No reload, no per-command patch.
	  * Tests can stub the allowlist and verify the gate without
	    touching Cmdr.

	Concurrency note: the allowlist is a flat table, mutated in
	place by Add / Remove. Roblox Luau does not guarantee atomic
	visibility across resumable boundaries, but for this gate the
	worst case is a single frame's stale read, which is harmless
	(the next command read sees the truth). No mutex needed.
]]

local AdminConfig = require(script.Parent.AdminConfig)

local AdminService = {}

-- --- Reads ------------------------------------------------------

-- True if the userId is in the allowlist, regardless of rank.
function AdminService.IsAdmin(userId: number): boolean
	if typeof(userId) ~= 'number' then
		return false
	end
	local entry = AdminConfig.Admins[userId]
	return entry ~= nil and entry.rank ~= nil
end

-- Returns the rank string for the userId, or nil if not admin.
function AdminService.GetRank(userId: number): string?
	if typeof(userId) ~= 'number' then
		return nil
	end
	local entry = AdminConfig.Admins[userId]
	if not entry then
		return nil
	end
	return entry.rank
end

-- The numeric rank for the userId, or 0 for "not an admin".
-- Cmdr groups are strings; comparisons are by integer rank so
-- a future "owner" or "developer" rank doesn't need a code
-- change to be considered above superadmin.
function AdminService.GetRankLevel(userId: number): number
	local rank = AdminService.GetRank(userId)
	if not rank then
		return 0
	end
	local level = AdminConfig.RankOrder[rank]
	return level or 0
end

-- --- Permission gate --------------------------------------------

-- Can the userId run a command of `requiredRank`? True iff the
-- user is an admin AND their rank level is >= the required level.
-- 'Default' (or nil) means the command is open to everyone and
-- always returns true.
function AdminService.CanRun(userId: number, requiredRank: string?): boolean
	if requiredRank == nil or requiredRank == AdminConfig.DefaultGroup or requiredRank == '' then
		return true
	end
	local requiredLevel = AdminConfig.RankOrder[requiredRank]
	if not requiredLevel then
		-- Unknown rank name: refuse by default. Better to deny
		-- than to silently allow a typo'd group to be a free
		-- pass.
		return false
	end
	return AdminService.GetRankLevel(userId) >= requiredLevel
end

-- Throws if the userId can't run a command of the given rank.
-- Used as the first line of every admin command's Run function.
-- The error message is what Cmdr surfaces back to the player
-- in chat, so it has to be human-readable.
function AdminService.AssertCanRun(userId: number, requiredRank: string?)
	if not AdminService.CanRun(userId, requiredRank) then
		local rank = AdminService.GetRank(userId)
		local msg
		if rank then
			msg = string.format(
				'[Admin] you are rank %q; this command requires rank %q.',
				rank,
				requiredRank or 'Default'
			)
		else
			msg =
				string.format('[Admin] you are not an admin; this command requires rank %q.', requiredRank or 'Default')
		end
		error(msg, 2)
	end
end

-- Convenience: throw if the userId is not an admin at all.
-- Used by commands that should not reveal what rank they need —
-- you either are an admin or you aren't.
function AdminService.AssertAdmin(userId: number)
	if not AdminService.IsAdmin(userId) then
		error('[Admin] you are not an admin.', 2)
	end
end

-- --- Mutations (for /addadmin / /removeadmin) -------------------

-- Add or update an admin. Returns true on success, false on
-- invalid input. Mutations are in-place; future reads see the
-- new state.
function AdminService.AddAdmin(userId: number, rank: string): boolean
	if typeof(userId) ~= 'number' or userId < 0 then
		return false
	end
	if typeof(rank) ~= 'string' then
		return false
	end
	if not AdminConfig.RankOrder[rank] then
		return false
	end
	-- Reuse the table for the existing entry if any; otherwise
	-- allocate a new one. Keeping the same table means callers
	-- that hold a reference see the update without re-querying.
	local existing = AdminConfig.Admins[userId]
	if existing then
		existing.rank = rank
	else
		AdminConfig.Admins[userId] = { rank = rank }
	end
	return true
end

-- Remove an admin. Returns true if the userId was present and
-- is now gone, false if they weren't in the list to begin with.
function AdminService.RemoveAdmin(userId: number): boolean
	if typeof(userId) ~= 'number' then
		return false
	end
	local entry = AdminConfig.Admins[userId]
	if not entry then
		return false
	end
	AdminConfig.Admins[userId] = nil
	return true
end

-- --- Introspection (for /listadmins) ---------------------------

-- Return a sorted list of {userId, rank} pairs. Stable order so
-- /listadmins output is reproducible. Used by the listadmins
-- command.
function AdminService.ListAdmins(): { { userId: number, rank: string } }
	local out = {}
	for userId, entry in pairs(AdminConfig.Admins) do
		out[#out + 1] = { userId = userId, rank = entry.rank }
	end
	table.sort(out, function(a, b)
		if a.rank == b.rank then
			return a.userId < b.userId
		end
		return (AdminConfig.RankOrder[a.rank] or 0) < (AdminConfig.RankOrder[b.rank] or 0)
	end)
	return out
end

return table.freeze(AdminService)
