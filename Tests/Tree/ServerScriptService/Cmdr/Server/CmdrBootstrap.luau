--!strict
--!native
--[[
	CmdrBootstrap
	============
	Server-side Cmdr bootstrap. One script that:
	  1. Requires Cmdr (the server entry point).
	  2. Registers the built-in commands (help, version, credits).
	  3. Walks the Commands folder and registers each module.
	  4. Exposes a sanity check in the Output window so a
	     developer can see the loaded command count at startup.

	Cmdr 1.12.0 specifics:
	  * Entry point is `Packages.Cmdr` (the Cmdr init.lua at
	    ServerPackages/_Index/.../cmdr/Cmdr/init.lua).
	  * `RegisterCommandsIn(folder, filter)` walks the folder,
	    `require()`s each ModuleScript, and treats the return
	    value as the command definition table.
	  * The filter receives the COMMAND OBJECT (not the calling
	    player). Per-player permission gating happens inside
	    each command's Run function via AdminService.

	The filter we use here is "accept all" — every registered
	command file ships, and the per-player gate is
	AdminService.AssertCanRun in each Run. This keeps the
	bootstrap simple and the security model uniform: every
	admin command checks the same way.

	Studio-only safety: this script is a server script so it
	runs in normal playtests and in the live game. Cmdr's
	client GUI shows up automatically.
]]

local RunService = game:GetService('RunService')

-- Cmdr's package is mapped under ServerScriptService.Packages
-- (Wally's ServerPackages path) by the Rojo project file.
local ServerScriptService = game:GetService('ServerScriptService')
local Packages = ServerScriptService:WaitForChild('Packages')
local Cmdr = require(Packages:WaitForChild('Cmdr'))

-- The commands folder is a sibling of this script. The Cmdr
-- command modules live alongside CmdrBootstrap.server.lua and
-- each returns a plain command-definition table.
local CommandsFolder = script.Parent:WaitForChild('Commands')

-- Custom admin argument types (adminTarget, eggRarity, animalDef,
-- traitId, mutationList, gearId, codeId, arenaOption). Each module
-- returns `function(cmdr)` and is registered here; registration
-- moves the modules to the replicated Types folder so the client
-- console gets the same canonical autocomplete the server
-- validates against. Types MUST register before commands (command
-- definitions reference them by name).
local TypesFolder = script.Parent:WaitForChild('Types')

-- --- Built-in commands ------------------------------------------

-- Cmdr's built-in commands (help, version, credits) ship in
-- `Packages.Cmdr.BuiltInCommands`. We register them for everyone;
-- they have Group = "Default" so the per-player admin gate is
-- skipped. The first arg is the filter — true means register.
Cmdr.Registry:RegisterDefaultCommands(function(_command)
	return true
end)

-- --- BeforeRun hook (MUST precede command execution) --------------

-- Cmdr 1.12.0 executes commands through
-- Dispatcher:RunHooks("BeforeRun"), which BLOCKS execution
-- ("Command blocked ... as no BeforeRun hook is configured")
-- while Registry.Hooks.BeforeRun is EMPTY. The hook therefore
-- has to be registered via Registry:RegisterHook on THIS
-- Registry — the same instance the server Dispatcher runs
-- against. (A `Cmdr.BeforeRun =` assignment is a dead table
-- field nothing reads; that was the multiplayer bug.) Return
-- nil / nothing allows the command to proceed; a non-nil
-- string blocks with that message.
--
-- Pass-through by design: per-command AdminService.AssertAdmin
-- gates inside each Run remain the single authorization
-- authority (built-ins are Group Default and intentionally
-- ungated), so server-side admin security is unchanged.
Cmdr.Registry:RegisterHook('BeforeRun', function(_context)
	return nil
end)

-- --- Custom admin types -----------------------------------------

-- Register the admin argument types first (see TypesFolder note
-- above). accept-all filter mirrors the command policy: the
-- per-player gate is AdminService inside each Run, never the
-- type layer (types only shape text, they grant nothing).
Cmdr.Registry:RegisterTypesIn(TypesFolder)

-- --- Custom commands --------------------------------------------

-- Walk the Commands folder and register every ModuleScript.
-- The filter only sees the command; AdminService.AssertCanRun
-- inside each Run is the actual per-player gate.
Cmdr.Registry:RegisterCommandsIn(CommandsFolder, function(_command)
	return true
end)

-- --- Diagnostics ------------------------------------------------

-- Print the command count so the developer can confirm Cmdr
-- loaded the expected number of files. If the count is wrong
-- the cause is almost always a Lua error in one of the command
-- modules (a typo in Name, an unknown arg property, etc.) that
-- caused Cmdr to throw and skip the rest of the folder.
local commandCount = 0
for _ in pairs(Cmdr.Registry:GetCommands()) do
	commandCount += 1
end
local hookCount = #Cmdr.Registry.Hooks.BeforeRun
if hookCount == 0 then
	warn('[CmdrBootstrap] BeforeRun hook NOT registered — commands will be blocked')
end

if RunService:IsStudio() then
	print(('[CmdrBootstrap] registered %d commands + %d BeforeRun hook(s) (Studio)'):format(commandCount, hookCount))
else
	print(('[CmdrBootstrap] registered %d commands + %d BeforeRun hook(s) (Server)'):format(commandCount, hookCount))
end

return nil
