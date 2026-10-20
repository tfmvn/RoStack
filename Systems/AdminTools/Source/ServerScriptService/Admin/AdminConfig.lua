--!strict
--!native
--[[
	AdminConfig
	===========
	Single source of truth for who is an admin and at what rank.

	Rank order (low -> high): mod, admin, superadmin.
	Higher rank commands can run lower rank commands too. Cmdr
	groups mirror these names (Cmdr.Group is a string the command
	author can read in the filter callback; in Cmdr 1.12 the
	filter only sees the command, not the calling player, so the
	per-player gate happens inside the Run function via
	AdminService.AssertAtLeast).

	Adding a new admin: add a userId to the table with the
	desired rank. userIds can be offline (Cmdr's admin commands
	take a number for /addadmin so an admin can grant power
	before the player ever joins).

	Removing an admin: use /removeadmin at runtime (it mutates
	this table in-place). For a hard wipe, edit the source and
	restart the server.

	Note: the allowlist below is EMPTY by default. Add your own
	discord-roblox userIds in a private fork or use /addadmin at
	runtime to bootstrap. Empty default = no one is an admin =
	safe default for a public Studio build.
]]

local AdminConfig = {}

-- The allowlist. Each entry is { rank = "<rank>" }.
-- Cmdr's permission model is "Group == rank"; the rank string
-- is also the Group string on every command. Keeping the names
-- in lockstep means the source of truth is a single lookup.
AdminConfig.Admins = {
	-- Example entries (commented out — populate with your own
	-- userIds before exposing the server to a public audience):
	-- [12345678] = { rank = 'superadmin' },
	-- [87654321] = { rank = 'admin' },
	-- [11111111] = { rank = 'mod' },
	--
	-- SECURITY NOTE (library extraction): the source game shipped a
	-- live allowlist here — two real userIds plus the Studio test
	-- ids 0, 1 and 2 — with NO IsStudio() gate on the Studio ids.
	-- Those entries are removed. The allowlist is now empty, which
	-- is the safe default: nobody is an admin until you add someone.
	--
	-- To bootstrap, either add your userIds below, or grant yourself
	-- at runtime with /addadmin from a server console.
	--
	-- If you add the Studio test ids, gate them yourself:
	--   if RunService:IsStudio() then AdminConfig.Admins[0] = ... end
}

-- Rank ordering. Lower index = lower rank. Anything not in this
-- list is rejected by CanRun / AssertAtLeast. Cmdr's built-in
-- commands (help, etc.) use Group = "Default" and are exempt
-- from the rank check.
AdminConfig.RankOrder = {
	mod = 1,
	admin = 2,
	superadmin = 3,
}

-- Cmdr group name for the default (non-admin) commands. Cmdr's
-- own help / version / credits commands use this. Exposed here
-- so the bootstrap can use the same string everywhere.
AdminConfig.DefaultGroup = 'Default'

-- Cmdr group name for mod-tier commands. Currently a marker;
-- every command in the v1 suite is admin-tier so this is
-- documentation only.
AdminConfig.ModGroup = 'Mod'

-- Cmdr group name for admin commands. Every command file in
-- `Cmdr/Server/Commands/` declares Group = AdminConfig.AdminGroup
-- (or superadmin) so the registration code is uniform.
AdminConfig.AdminGroup = 'Admin'

-- Cmdr group name for superadmin-only commands. /addadmin,
-- /removeadmin, and /shutdown live in this group.
AdminConfig.SuperadminGroup = 'Superadmin'

-- Sanity-check the rank order is monotonic. The check is
-- evaluated at module load so a typo in RankOrder throws on
-- server start, not on first admin command.
assert(AdminConfig.RankOrder.mod < AdminConfig.RankOrder.admin, 'AdminConfig.RankOrder: mod must be < admin')
assert(
	AdminConfig.RankOrder.admin < AdminConfig.RankOrder.superadmin,
	'AdminConfig.RankOrder: admin must be < superadmin'
)

return table.freeze(AdminConfig)
