--!strict
--!native
--[[
	TestRunner
	==========
	TestEZ bootstrap for the reusable-systems library.

	Mounted by `ReusableSystems/test.project.json` at
	`ServerScriptService/TestEZTests/`, alongside every spec file
	(the specs are mounted FLAT into that one folder so that
	`require(script.Parent._Helpers)` resolves — see the project file
	for the full explanation).

	Run it with the TestEZ command bar button, or by running this
	script in Studio.

	WHY THIS FILE EXISTS AND WHAT IT DOES NOT DO
	--------------------------------------------
	There is no headless Luau test runner in this repository, and
	TestEZ is a Roblox-runtime library — it cannot be executed outside
	Studio. This script is therefore the *only* way the library's 89
	specs can be run, and it requires a published place if any spec
	touches a DataStore.

	`TestEZ.run(testRoot, callback)` is the correct 0.4.1 entry point.
	There is no `TestEZ.RunBootstrap()` in 0.4.1 (that was a 0.3-era
	API); calling it raises "attempt to call a nil value" at runtime.

	`testRoot` is a Folder containing the spec modules. The callback
	receives a `TestResults` with `successCount`, `failureCount`,
	`skippedCount`, `errors`, and a `nodes` tree.
]]

-- TestEZ 0.4.1 lives under Packages.DevPackages when mounted by the
-- library's test project (it is a dev-only dependency and must not be
-- shipped in the production build).
local TestEZ = require(script.Parent.Parent.Packages.DevPackages.TestEZ)

local testRoot = script.Parent

print('[reusable-systems] running TestEZ over', testRoot:GetFullName())

TestEZ.run(testRoot, function(results)
	TestEZ.Reporters.TextReporter.report(results)

	if results.failureCount > 0 then
		-- Make the failure loud in the Studio output so it is not
		-- scrolled past. The reporter already prints each error via
		-- TestService:Error.
		warn(('[reusable-systems] %d test(s) FAILED'):format(results.failureCount))
	else
		print(('[reusable-systems] all %d test(s) passed'):format(results.successCount))
	end
end)
