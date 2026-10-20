--!strict
--[[
	AdminTools — consolidated tunables
	==================================
	A read-only, commented copy of every tunable the admin system
	exposes.

	This file does NOT change the behaviour of the running game:
	nothing requires it. The tunables live as literals inside
	`ServerScriptService/Admin/AdminConfig.lua` and
	`ReplicatedStorage/Config/Systems/Security.lua`.

	It exists so a new game can see every knob in one place and copy
	the values it wants to change into its own copy of those modules.

	When you fork the system, edit the literals in `AdminConfig.lua`
	and `Security.lua` directly (and mirror them here), or replace
	these modules with a real config and change the requires.
]]

local AdminToolsConfig = {}

-- ---------------------------------------------------------------------------
-- The admin allowlist  (Grade B — ENVIRONMENT-SPECIFIC)
-- ---------------------------------------------------------------------------

-- The allowlist: userId -> { rank = '<rank>' }.
--
-- DEFAULT: {} — EMPTY.
-- MEANING: the set of userIds allowed to run admin commands, and
--   their rank. A flat numeric table, so an OFFLINE userId works:
--   an admin can grant power to a player who has never joined.
--   `AdminService.IsAdmin` / `GetRank` / `CanRun` all read this
--   table; `AddAdmin` / `RemoveAdmin` mutate it in place.
-- VALID RANGE: any non-negative integer userId; the rank string
--   must be a key of `RankOrder` below.
-- SAFE TO CHANGE: yes — this is the file you are meant to edit.
-- READ BY: `AdminService.IsAdmin` (AdminService.lua:43),
--   `AdminService.GetRank` (:52), `AdminService.AddAdmin` (:141),
--   `AdminService.RemoveAdmin` (:156), `AdminService.ListAdmins`
--   (:171).
-- PLACEHOLDER: YES — and that is deliberate.
--
--   SECURITY NOTE (library extraction). The source game shipped a
--   LIVE allowlist here: two real userIds plus the Studio test ids
--   0, 1 and 2, with NO RunService:IsStudio() gate on the Studio
--   ids. Those entries were removed at extraction. The ids 0/1/2
--   are always joined in a Studio playtest and are always real
--   players in a live server, so an ungated allowlist for them is a
--   production backdoor.
--
--   Bootstrap options:
--     (a) add your own userIds below, statically; or
--     (b) grant yourself at runtime with `/addadmin <userId>
--         superadmin` from a server console.
--
--   NOTE: `/addadmin` is one of the three commands that are
--   currently BROKEN in this suite (see the `RankOrder` note
--   below), so option (b) does not work out of the box. Option (a)
--   is the reliable path until the bug is fixed.
--
--   If you want Studio-only admins, gate them yourself:
--       local RunService = game:GetService('RunService')
--       if RunService:IsStudio() then
--           AdminConfig.Admins[0] = { rank = 'superadmin' }
--       end
AdminToolsConfig.Admins = {
	-- [12345678] = { rank = 'superadmin' },
	-- [87654321] = { rank = 'admin' },
	-- [11111111] = { rank = 'mod' },
}

-- ---------------------------------------------------------------------------
-- Ranks
-- ---------------------------------------------------------------------------

-- The rank order, low -> high.
--
-- DEFAULT: { mod = 1, admin = 2, superadmin = 3 }.
-- MEANING: the numeric level of each rank. `AdminService.CanRun`
--   compares the caller's level against the required level. A
--   higher rank can run every lower-rank command. `GetRankLevel`
--   returns 0 for a non-admin.
-- VALID RANGE: positive integers, strictly increasing.
-- SAFE TO CHANGE: yes, but see the CASE WARNING below.
-- READ BY: `AdminService.GetRankLevel` (AdminService.lua:68),
--   `AdminService.CanRun` (:82), `AdminService.AddAdmin` (:135),
--   `AdminService.ListAdmins` (:178). `AdminConfig.lua:89-93`
--   asserts `mod < admin < superadmin` AT MODULE LOAD.
-- PLACEHOLDER: no — but there is a live bug here, described below.
--
--   *** CASE WARNING — READ THIS BEFORE YOU SHIP ***
--   The keys here are LOWER CASE. `AdminConfig.SuperadminGroup`
--   (and `AdminGroup`, `ModGroup`) are CAPITALISED group names
--   ('Superadmin', 'Admin', 'Mod'), and they are NOT keys of this
--   table. `AdminService.CanRun` looks the required rank up
--   VERBATIM:
--       local requiredLevel = AdminConfig.RankOrder[requiredRank]
--       if not requiredLevel then return false end   -- unknown -> DENY
--   So `AssertCanRun(userId, AdminConfig.SuperadminGroup)`
--   looks up RankOrder['Superadmin'] -> nil -> DENIES EVERYONE.
--
--   Three commands are affected:
--     /addadmin    (addAdminServer.lua:19)
--     /removeadmin (removeAdminServer.lua:19)
--     /shutdown    (shutdownServer.lua:19)
--   All three are therefore UNUSABLE as shipped — even for a
--   superadmin. The other four superadmin commands use the
--   lowercase literal 'superadmin' and work correctly.
--
--   The one-line fix (in `AdminService.CanRun`):
--       local requiredLevel =
--           AdminConfig.RankOrder[string.lower(requiredRank)]
--   `'Superadmin'` -> 'superadmin' and `'Admin'` -> 'admin', both
--   of which ARE keys above. That single change fixes all three
--   broken commands at once.
--
--   Alternatively, re-key this table with the capitalised group
--   names ('Mod'/'Admin'/'Superadmin') and change every call site
--   to use the lower-case literal.
AdminToolsConfig.RankOrder = {
	mod = 1,
	admin = 2,
	superadmin = 3,
}

-- The Cmdr group name for commands open to everyone.
--
-- DEFAULT: 'Default'.
-- MEANING: Cmdr's own built-in commands (help, version, credits)
--   use this group. `AdminService.CanRun` treats 'Default' (and
--   nil and '') as "always allowed", so these commands are never
--   gated.
-- VALID RANGE: any string; must match the Cmdr `Group` field of
--   the commands that use it.
-- SAFE TO CHANGE: yes, but it must match Cmdr's built-ins.
-- READ BY: `AdminService.CanRun` (AdminService.lua:79).
-- PLACEHOLDER: no.
AdminToolsConfig.DefaultGroup = 'Default'

-- The Cmdr group name for mod-tier commands.
--
-- DEFAULT: 'Mod'.
-- MEANING: declared for completeness. EVERY command in the v1
--   suite is admin-tier, so no command currently uses this group
--   and no rank check references it. It is documentation only.
-- VALID RANGE: any string.
-- SAFE TO CHANGE: yes, but a 'Mod' group with no commands is
--   invisible in the client console.
-- READ BY: nothing today. Exposed for future mod-tier commands.
-- PLACEHOLDER: yes — reserved.
AdminToolsConfig.ModGroup = 'Mod'

-- The Cmdr group name for admin-tier commands.
--
-- DEFAULT: 'Admin'.
-- MEANING: the `Group` field on 61 of the 68 command definitions.
--   IMPORTANT: the Group is METADATA ONLY — Cmdr's registration
--   filter receives the command object and never the calling
--   player, so the Group cannot gate anything. The real gate is
--   `AdminService.AssertAdmin` / `AssertCanRun` as the first
--   statement of each command's Run function.
-- VALID RANGE: any string.
-- SAFE TO CHANGE: yes for the metadata, but you must also change
--   the `Group` field on every command definition that uses it.
-- READ BY: the 61 `Group = 'Admin'` command definitions; the
--   AdminFramework spec asserts `def.Group` is one of
--   'Admin' / 'Superadmin' / 'Default'.
-- PLACEHOLDER: no.
AdminToolsConfig.AdminGroup = 'Admin'

-- The Cmdr group name for superadmin-only commands.
--
-- DEFAULT: 'Superadmin'.
-- MEANING: the `Group` field on 7 command definitions
--   (/addadmin, /cancelsteal, /removeadmin, /removeanimal,
--   /removeegg, /resetarena, /shutdown). ALSO the string passed
--   to `AssertCanRun` by three of them — which is the case bug
--   described in the `RankOrder` note above.
-- VALID RANGE: any string.
-- SAFE TO CHANGE: only together with the `RankOrder` keys.
-- READ BY: `AdminService.AssertCanRun` via the three command Run
--   functions that pass `AdminConfig.SuperadminGroup`.
-- PLACEHOLDER: no.
AdminToolsConfig.SuperadminGroup = 'Superadmin'

-- ---------------------------------------------------------------------------
-- Rate limit  (Grade A)
-- ---------------------------------------------------------------------------

-- The admin command sliding-window budget.
--
-- DEFAULT: WindowSeconds = 10, MaxPerWindow = 30,
--   MinGapSeconds = 0.2.
-- MEANING: each admin may run at most 30 commands per 10-second
--   window, and no two commands closer together than 0.2 s (a
--   5-per-second burst cap). Exceeding either fails THAT ONE
--   execution with a plain message. There is NO punishment and NO
--   lockout.
-- VALID RANGE:
--   WindowSeconds  > 0 (Security.Validate asserts this)
--   MaxPerWindow   > 0 (Security.Validate asserts this)
--   MinGapSeconds  >= 0 (NOT asserted by Security.Validate)
-- SAFE TO CHANGE: yes — but a RESTART IS REQUIRED.
-- READ BY: `AdminRateLimit` (AdminRateLimit.lua:26-28). The three
--   values are snapshotted into module-local variables AT MODULE
--   LOAD, so editing `Security.Admin` at runtime has NO effect.
-- PLACEHOLDER: no.
--
-- The source of truth is `ReplicatedStorage.Config.Systems.Security`,
-- which also carries the receipts / door / placement budgets.
-- `Security.Validate()` checks WindowSeconds and MaxPerWindow.
AdminToolsConfig.RateLimit = {
	WindowSeconds = 10,
	MaxPerWindow = 30,
	MinGapSeconds = 0.2,
}

-- ---------------------------------------------------------------------------
-- Audit  (Grade A)
-- ---------------------------------------------------------------------------

-- The audit ring-buffer capacity.
--
-- DEFAULT: 100.
-- MEANING: how many recent admin executions `AdminAudit.Recent` can
--   return and how many the buffer keeps. The 101st entry evicts
--   the first. `/adminlog` shows a minimum of 10 and a maximum of
--   100.
-- VALID RANGE: >= 1.
-- SAFE TO CHANGE: yes — but it is a LITERAL inside
--   `AdminAudit.lua:22`, not a config value. Edit the source.
-- READ BY: `AdminAudit.Log` (the eviction check) and
--   `AdminAudit.Recent` (the clamp).
-- PLACEHOLDER: no.
AdminToolsConfig.AuditBufferSize = 100

-- The default number of audit entries `/adminlog` shows.
--
-- DEFAULT: 10.
-- MEANING: `AdminAudit.Recent(nil)` — and `/adminlog` with no
--   argument — return this many entries, newest first.
-- VALID RANGE: >= 1.
-- SAFE TO CHANGE: yes — it is a LITERAL inside
--   `AdminAudit.Recent` (AdminAudit.lua:67), not a config value.
-- READ BY: `AdminAudit.Recent`.
-- PLACEHOLDER: no.
AdminToolsConfig.AuditDefaultCount = 10

-- The audit result truncation lengths.
--
-- DEFAULT: lineResult = 160, flatResult = 180.
-- MEANING: the ring-buffer line's `:: <result>` tail is truncated to
--   160 characters; the `Debug.Log` flat map's `result` field is
--   truncated to 180. The flat map keeps the longer, more detailed
--   value for the Studio/output trail.
-- VALID RANGE: >= 0.
-- SAFE TO CHANGE: yes — both are LITERALS inside `AdminAudit.lua`
--   (lines 47 and 57), not config values.
-- READ BY: `AdminAudit.Log`.
-- PLACEHOLDER: no.
AdminToolsConfig.AuditTruncation = {
	LineResult = 160,
	FlatResult = 180,
}

-- ---------------------------------------------------------------------------
-- Argument ceilings  (Grade A — read from the canonical game configs)
-- ---------------------------------------------------------------------------

-- The animal-level ceiling.
--
-- DEFAULT: read live from `Config.Creatures.Progression.MaxLevel`.
-- MEANING: `AdminArgs.ResolveAnimalLevel` rejects anything above
--   this. `/giveanimal`'s `level` argument and `/setanimallevel`'s
--   `level` argument are both bounded by it (the command
--   descriptions say "1-100", which matches the shipped value).
-- VALID RANGE: >= 1.
-- SAFE TO CHANGE: no — it is NOT a local tunable. Change
--   `Config/Creatures/Progression.lua`.
-- READ BY: `AdminArgs.ResolveAnimalLevel` (AdminArgs.lua:206).
-- PLACEHOLDER: no.
AdminToolsConfig.MaxAnimalLevel = 100 -- from Progression.MaxLevel

-- The admin-only level cap used by `/setlevel`.
--
-- DEFAULT: read live from `Config.Creatures.Progression.AdminLevelCap`.
-- MEANING: `/setlevel` is a PLACEHOLDER no-op; it validates its
--   level against this cap and then returns "setlevel is a
--   placeholder". The cap exists so the command's contract is
--   already correct when the level system is built.
-- VALID RANGE: >= 1.
-- SAFE TO CHANGE: no — change
--   `Config/Creatures/Progression.lua`.
-- READ BY: `setLevelServer.lua`.
-- PLACEHOLDER: the whole command is a placeholder.
AdminToolsConfig.AdminLevelCap = 99 -- from Progression.AdminLevelCap

-- The arena-stage ceiling.
--
-- DEFAULT: `ArenaConfig.MaxLevel()`, with a hard FALLBACK of 50 if
--   that call fails.
-- MEANING: `AdminArgs.ResolveArenaLevel` bounds the arena stage
--   of `/givearenawin`.
-- VALID RANGE: >= 1.
-- SAFE TO CHANGE: no — it is read from
--   `Config/World/Arena.lua` at call time, inside a pcall.
-- READ BY: `AdminArgs.ResolveArenaLevel` (AdminArgs.lua:218-220).
-- PLACEHOLDER: no. The 50 fallback is a hard-coded literal in
--   `AdminArgs.lua:217`.
AdminToolsConfig.MaxArenaLevel = 50 -- from ArenaConfig.MaxLevel()

-- The rebirth-index ceiling.
--
-- DEFAULT: `RebirthConfig.MaxConfigured()`, with a hard FALLBACK of
--   3 if that call fails.
-- MEANING: `AdminArgs.ResolveRebirthIndex` bounds the rebirth
--   index. The valid range is 0-based (0 is the first rebirth).
-- VALID RANGE: >= 0.
-- SAFE TO CHANGE: no — read from `Config/Economy/Rebirth.lua`
--   at call time, inside a pcall.
-- READ BY: `AdminArgs.ResolveRebirthIndex` (AdminArgs.lua:232-234).
-- PLACEHOLDER: no. The 3 fallback is a hard-coded literal in
--   `AdminArgs.lua:232`.
AdminToolsConfig.MaxRebirthIndex = 3 -- from RebirthConfig.MaxConfigured()

-- The grant quantity ceilings.
--
-- DEFAULT: animals = 5, eggs = 10, spawned center eggs = 10.
-- MEANING: the `maxQty` argument passed to
--   `AdminArgs.ResolveQuantity` by each grant command. Exceeding it
--   is an error, not a clamp.
--   * /giveanimal  -> 5   (AdminArgs call in giveAnimalServer.lua)
--   * /giveegg     -> 10  (AdminArgs call in giveEggServer.lua)
--   * /spawnegg    -> 10  (its own bound in spawnEggServer.lua)
-- VALID RANGE: >= 1.
-- SAFE TO CHANGE: yes — they are LITERALS in the command Run
--   functions, not config values. Edit the source.
-- READ BY: the three command Run functions.
-- PLACEHOLDER: no.
AdminToolsConfig.MaxGrantQuantity = {
	Animals = 5,
	Eggs = 10,
	SpawnedEggs = 10,
}

-- ---------------------------------------------------------------------------
-- Notification limits  (Grade A)
-- ---------------------------------------------------------------------------

-- The `/tell` message length cap.
--
-- DEFAULT: 240 characters.
-- MEANING: the maximum length of the private admin message in
--   `/tell`. Longer input is rejected.
-- VALID RANGE: >= 1.
-- SAFE TO CHANGE: yes — it is a LITERAL in `tellServer.lua`, not a
--   config value.
-- READ BY: `tellServer.lua`.
-- PLACEHOLDER: no.
AdminToolsConfig.TellMessageMaxChars = 240

-- The `/ragdoll` duration bounds.
--
-- DEFAULT: min = 1, max = 30, default = 5 (seconds).
-- MEANING: `/ragdoll <target> [duration]` clamps or rejects the
--   duration. The `duration` argument is optional and defaults to
--   5 seconds.
-- VALID RANGE: 1 .. 30.
-- SAFE TO CHANGE: yes — LITERALS in `ragdollServer.lua`.
-- READ BY: `ragdollServer.lua`.
-- PLACEHOLDER: no.
AdminToolsConfig.RagdollDuration = {
	Min = 1,
	Max = 30,
	Default = 5,
}

-- The `/speed` bounds.
--
-- DEFAULT: min = 0, max = 200 (WalkSpeed studs/second).
-- MEANING: `/speed <value>` sets the executor's `Humanoid.WalkSpeed`.
--   A value of 0 freezes the character.
-- VALID RANGE: 0 .. 200.
-- SAFE TO CHANGE: yes — LITERALS in `speedServer.lua`.
-- READ BY: `speedServer.lua`.
-- PLACEHOLDER: no.
AdminToolsConfig.SpeedRange = {
	Min = 0,
	Max = 200,
}

-- The `/setmoneymultiplier` bounds.
--
-- DEFAULT: min = 0.01, max = 100.
-- MEANING: `/setmoneymultiplier <target> <value>` sets the
--   `AdminOverride` money multiplier through
--   `ModifierService`. `/clearmoneymultiplier` removes it.
-- VALID RANGE: 0.01 .. 100.
-- SAFE TO CHANGE: yes — LITERALS in `setMoneyMultiplierServer.lua`.
-- READ BY: `setMoneyMultiplierServer.lua`.
-- PLACEHOLDER: no.
AdminToolsConfig.MoneyMultiplierRange = {
	Min = 0.01,
	Max = 100,
}

-- The `/slowmode` bounds.
--
-- DEFAULT: min = 0, max = 60 (seconds).
-- MEANING: `/slowmode` is a PLACEHOLDER no-op — it validates the
--   seconds against this range and then returns "slowmode is a
--   placeholder". The bounds exist so the contract is already
--   correct when a chat service is wired.
-- VALID RANGE: 0 .. 60.
-- SAFE TO CHANGE: yes — LITERALS in `slowmodeServer.lua`.
-- READ BY: `slowmodeServer.lua`.
-- PLACEHOLDER: the whole command is a placeholder.
AdminToolsConfig.SlowmodeRange = {
	Min = 0,
	Max = 60,
}

-- ---------------------------------------------------------------------------
-- Command-suite facts  (Grade B — Brainrot Arena's admin surface)
-- ---------------------------------------------------------------------------

-- The number of Cmdr commands in the suite.
--
-- DEFAULT: 68 (61 in the 'Admin' group, 7 in the 'Superadmin'
--   group), across 136 source files (68 definitions + 68 Run
--   functions).
-- MEANING: the expected value of the bootstrap's startup print,
--   "[CmdrBootstrap] registered N commands ...". A lower number
--   means a command module threw during registration — Cmdr's
--   RegisterCommandsIn has NO pcall, so one bad file silently
--   skips every command after it in the folder. The count is the
--   only signal you get.
--   The count ALSO includes Cmdr's 3 built-ins (help, version,
--   credits), so the real total is 68 admin commands + 3 built-ins
--   = 71 registered entries.
-- VALID RANGE: >= 71.
-- SAFE TO CHANGE: yes — but keep the spec's `checked >= 60`
--   assertion in `Tests/AdminFramework.spec.lua` in sync.
-- READ BY: `CmdrBootstrap.luau:111-114` (the counter).
-- PLACEHOLDER: no.
AdminToolsConfig.CommandCount = 68

-- The Cmdr version this suite targets.
--
-- DEFAULT: 1.12.0 (`evaera/cmdr@~1.12.0`).
-- MEANING: the suite depends on 1.12-specific behaviour:
--   * `Registry.Hooks.BeforeRun` must be non-empty or Cmdr blocks
--     every command ("Command blocked ... as no BeforeRun hook is
--     configured");
--   * the server entry point is `Packages.Cmdr` (the init.lua at
--     ServerPackages/_Index/evaera_cmdr@1.12.0/cmdr/Cmdr/init.lua);
--   * `Registry:RegisterCommand(commandScript, commandServerScript,
--     filter)` pairs `<name>.lua` with `<name>Server.lua`;
--   * `Registry:RegisterTypesIn` and `Registry:RegisterCommand`
--     RE-PARENT the modules into `ReplicatedStorage.CmdrClient`.
-- 1.13.0 reshuffled the package layout (Command moved under
-- CmdrClient, init.luau uses `const`) and would need a different
-- bootstrap path.
-- VALID RANGE: 1.12.x.
-- SAFE TO CHANGE: no — not without rewriting the bootstrap.
-- READ BY: `CmdrBootstrap.luau` (the require and every Registry
--   call).
-- PLACEHOLDER: no.
AdminToolsConfig.CmdrVersion = '1.12.0'

-- ---------------------------------------------------------------------------
-- Placeholders — things that are NOT implemented
-- ---------------------------------------------------------------------------

-- The commands that exist but do nothing.
--
-- DEFAULT: { 'setlevel', 'slowmode' }.
-- MEANING: these two commands validate their arguments, write a
--   `Debug.Log('CMDR', '<name> (no-op placeholder)', ...)` line and
--   return a string saying they are placeholders.
--   * /setlevel  — needs a per-defId level system that does not
--     exist. See `AdminLevelCap` above.
--   * /slowmode  — needs a TextChatService integration that does
--     not exist. See `SlowmodeRange` above.
--   NOTE: they are 2 of the 23 commands that call NEITHER
--   `AdminRateLimit.Check` NOR `AdminAudit.Log` — see
--   `UnthrottledAndUnauditedCommands` below.
-- VALID RANGE: n/a.
-- SAFE TO CHANGE: yes — implement them, or delete the command
--   files. Do not ship them as working features.
-- READ BY: `setLevelServer.lua`, `slowmodeServer.lua`.
-- PLACEHOLDER: yes.
AdminToolsConfig.PlaceholderCommands = {
	'setlevel',
	'slowmode',
}

-- The commands whose declared Cmdr Group disagrees with their gate.
--
-- DEFAULT: { resetcash = 'Admin' } — declared 'Admin', gated at
--   'superadmin'.
-- MEANING: the `Group` field is metadata; the `AssertCanRun` call
--   in the Run function is the gate. For `/resetcash` the two
--   disagree and the gate wins, so the command is superadmin-only
--   in practice.
-- VALID RANGE: n/a.
-- SAFE TO CHANGE: yes — pick one and make them agree. Also fix the
--   three commands that use `AdminConfig.SuperadminGroup`
--   (`/addadmin`, `/removeadmin`, `/shutdown`); see the
--   `RankOrder` note above.
-- READ BY: `resetCashServer.lua:26`.
-- PLACEHOLDER: yes — an inconsistency in the shipped suite.
AdminToolsConfig.GroupMismatchCommands = {
	resetcash = 'Admin',
}

-- The commands that call NEITHER the rate limiter NOR the audit buffer.
--
-- DEFAULT: the 23 names below.
-- MEANING: 45 of the 68 commands call `AdminRateLimit.Check` (after
--   the permission gate) and `AdminAudit.Log` (on success and on
--   every failure path). The other 23 call neither — so they are
--   unbounded and leave no audit trace. Several of them are the
--   highest-impact commands in the suite.
-- VALID RANGE: n/a.
-- SAFE TO CHANGE: yes — add the two calls to any command that
--   mutates state.
-- READ BY: nothing reads this list; it is documentation of the
--   shipped coverage.
-- PLACEHOLDER: yes — an inconsistency in the shipped suite.
AdminToolsConfig.UnthrottledAndUnauditedCommands = {
	'addadmin',
	'announce',
	'bring',
	'event',
	'fly',
	'getplayerstats',
	'getstats',
	'givemoney',
	'givexp',
	'killcenteregg',
	'listcentereggs',
	'listplayers',
	'removeadmin',
	'resetplayer',
	'setlevel',
	'setmoney',
	'shutdown',
	'slowmode',
	'spawnegg',
	'speed',
	'tptobase',
	'tp',
	'wipeplayer',
}

return table.freeze(AdminToolsConfig)
