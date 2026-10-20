--!strict
--[[
	SystemConfigTemplate
	====================
	Copy this file into a new game's config tree and adapt it.

	PATTERN
	-------
	Every config domain in this library follows the same contract:

	  1. One module per DOMAIN, living at
	     `ReplicatedStorage.Config.<Domain>.<Domain>`.
	  2. The module returns a table of tunables. The table is
	     `table.freeze`d so nothing can mutate it at runtime.
	  3. The module exposes `Validate(): { string }` returning an
	     array of human-readable issue strings. An EMPTY array
	     means "valid". This is the contract the central
	     `ConfigValidator` relies on.
	  4. `ConfigValidator` calls every domain's `Validate()` at
	     boot. In Studio a failure is a hard error; in a live
	     server it is a warning (a bad tune must never hard-crash
	     production).

	SEPARATING THE FOUR KINDS OF VALUE
	----------------------------------
	Keep these apart — they have different lifetimes and different
	owners:

	  (a) Safe game-design settings — prices, multipliers, timers,
	      caps, probabilities. These belong in the domain config
	      module, exactly like this file. A designer may tune them
	      freely as long as the cross-config invariants still hold
	      (see the INVARIANTS section).

	  (b) Technical settings — retry counts, timeouts, throttle
	      windows, snapshot limits. These live in
	      `ReplicatedStorage.Config.Systems.Security` in the source
	      game. They are still tunable, but a change there is a
	      technical decision, not a balance decision.

	  (c) Environment-specific settings — DataStore names, product
	      ids, gamepass ids, event schedules, HTTP endpoints. These
	      MUST be swapped for a new game. Keep them in one place so
	      the swap is a single edit. The source game keeps them in
	      `Config/Economy/Shop.lua` (product ids), the DataStore
	      name literal in `PlayerService.lua`, and the daily/playtime
	      reset timezone in `Config/Economy/Rewards.lua`.

	  (d) Secrets and credentials — Discord webhook URLs, bot
	      tokens, Open Cloud keys. NEVER commit these and never
	      put them in a config module. Use a placeholder and read
	      the real value from a secure store (Roblox Open Cloud
	      `Secret` objects, or a server-side HTTP config endpoint
	      you control). See `../SECURITY_NOTES.md`.

	VALIDATION EXAMPLE
	------------------
	Every number below is checked for type and range. Booleans and
	strings are checked for type. The function returns issue
	strings, it does NOT error — the caller decides whether to
	error or warn.
]]

local Config = {}

-- --- Example: a price -------------------------------------------------

Config.Example = {
	-- Money cost of the first tier, as a BigNumber decimal string.
	-- Money in this codebase is NEVER a Lua number: it is a decimal
	-- string so that values beyond 2^53 stay exact.
	Price = '100',

	-- Multiplier applied to a derived value. Multipliers are also
	-- decimal strings, because they are folded into BigNumber
	-- arithmetic (exact terminating-decimal multiplication).
	Multiplier = '1.25',
}

-- --- Example: a timer -------------------------------------------------

Config.ExampleTimer = {
	-- How long the effect lasts, in seconds.
	DurationSeconds = 30,

	-- How often the effect re-applies, in seconds. Must be > 0 and
	-- <= DurationSeconds.
	IntervalSeconds = 5,
}

-- --- Example: a probability -------------------------------------------

Config.ExampleChance = {
	-- A normalised chance in [0, 1]. 0.25 == 25%.
	Rate = 0.25,
}

-- --- Example: a feature toggle ----------------------------------------

Config.Features = {
	-- When false, the feature's code paths are skipped entirely.
	Enabled = true,
}

-- --- Validation -------------------------------------------------------

--[[
	Return a list of issue strings. An empty list means valid.

	Rules that hold across this library:
	  * Never error from Validate(). The caller decides severity.
	  * Name the exact field path in every message.
	  * Report the expectation AND the received value.
	  * Validate RANGES, not just types. A negative timer is a
	    type-correct but broken value.
]]
function Config.Validate(): { string }
	local issues: { string } = {}

	-- Type checks.
	if type(Config.Example.Price) ~= 'string' then
		issues[#issues + 1] = 'Example.Price must be a string (BigNumber decimal)'
	end
	if type(Config.Example.Multiplier) ~= 'string' then
		issues[#issues + 1] = 'Example.Multiplier must be a string (BigNumber decimal)'
	end
	if type(Config.ExampleTimer.DurationSeconds) ~= 'number' then
		issues[#issues + 1] = 'ExampleTimer.DurationSeconds must be a number'
	end
	if type(Config.ExampleChance.Rate) ~= 'number' then
		issues[#issues + 1] = 'ExampleChance.Rate must be a number'
	end
	if type(Config.Features.Enabled) ~= 'boolean' then
		issues[#issues + 1] = 'Features.Enabled must be a boolean'
	end

	-- Range checks.
	if Config.ExampleTimer.DurationSeconds <= 0 then
		issues[#issues + 1] = 'ExampleTimer.DurationSeconds must be > 0'
	end
	if Config.ExampleTimer.IntervalSeconds <= 0 then
		issues[#issues + 1] = 'ExampleTimer.IntervalSeconds must be > 0'
	end
	if Config.ExampleTimer.IntervalSeconds > Config.ExampleTimer.DurationSeconds then
		issues[#issues + 1] = 'ExampleTimer.IntervalSeconds must be <= DurationSeconds'
	end
	if Config.ExampleChance.Rate < 0 or Config.ExampleChance.Rate > 1 then
		issues[#issues + 1] = 'ExampleChance.Rate must be in [0, 1]'
	end

	return issues
end

--[[
	Freeze the tables. Freezing prevents a runtime bug (or a
	third-party script) from mutating a tuning value mid-session,
	which is nearly impossible to debug later.

	Freeze the nested tables too, otherwise the top-level freeze
	gives no protection for nested fields.
]]
for _, t in { Config.Example, Config.ExampleTimer, Config.ExampleChance, Config.Features } do
	table.freeze(t)
end

return table.freeze(Config)
