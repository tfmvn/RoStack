--!strict
--[[
	ConfigValidator
	===============
	Central configuration validation for the UNIFIED config tree
	(ReplicatedStorage.Config/{Creatures,Economy,World,Presentation,Systems}).
	At boot (and in tests), every config domain's Validate() runs here;
	failures report the EXACT config, field, expectation, and received
	value — never a cryptic nil 20 stack frames later.

	CONTRACT
	--------
	* Each config domain (or subsection) exposes Validate() -> { string }
	  (empty = valid). Presentation-only domains without rules are
	  exempt (UI root/Notify, Messages).
	* ValidateAll() aggregates every domain's issues + the
	  cross-config invariants (ladders + joins). Pure — safe to
	  call from tests, bootstrap, and the Studio command bar.
	* Report(issues) formats the standard failure block.
	* AssertValid() errors with the full report (Studio fail-fast);
	  bootstrap catches it and warns in live servers so a bad tune
	  never hard-crashes production.

	ADDING A NEW CONFIG
	-------------------
	1. Give it Validate() -> { string }.
	2. Add it to _MODULES below (Path = folder segments; Sub = optional
	   subsection key for merged domains like Rewards.Codes).
	3. Add any cross-module invariant to _checkInvariants().
	4. Document it in docs/configuration/.
]]

local ReplicatedStorage = game:GetService('ReplicatedStorage')
local ConfigFolder = ReplicatedStorage:WaitForChild('Config')

local ConfigValidator = {}

-- Display name -> folder path (+ optional subsection). Every entry
-- must expose Validate().
local _MODULES: { { Name: string, Path: { string }, Sub: string? } } = {
	{ Name = 'World.Prompts', Path = { 'World', 'Prompts' } },
	{ Name = 'Economy.Money', Path = { 'Economy', 'Money' } },
	{ Name = 'World.ArenaFeel', Path = { 'World', 'ArenaFeel' } },
	{ Name = 'Economy.Sell', Path = { 'Economy', 'Sell' } },
	{ Name = 'Presentation.UI.Overhead', Path = { 'Presentation', 'UI' }, Sub = 'Overhead' },
	{ Name = 'World.Bases', Path = { 'World', 'Bases' } },
	{ Name = 'World.Movement', Path = { 'World', 'Movement' } },
	{ Name = 'World.Movement.Player', Path = { 'World', 'Movement' }, Sub = 'Player' },
	{ Name = 'Systems.Debug', Path = { 'Systems', 'Debug' } },
	{ Name = 'Presentation.Audio', Path = { 'Presentation', 'Audio' } },
	{ Name = 'Presentation.Vfx', Path = { 'Presentation', 'Vfx' } },
	{ Name = 'World.Stealing', Path = { 'World', 'Stealing' } },
	{ Name = 'Economy.Gear.Combat', Path = { 'Economy', 'Gear' }, Sub = 'Combat' },
	{ Name = 'Economy.Rebirth', Path = { 'Economy', 'Rebirth' } },
	{ Name = 'Economy.Rewards.Codes', Path = { 'Economy', 'Rewards' }, Sub = 'Codes' },
	{ Name = 'Economy.Rewards.Daily', Path = { 'Economy', 'Rewards' }, Sub = 'Daily' },
	{ Name = 'Economy.Rewards.Playtime', Path = { 'Economy', 'Rewards' }, Sub = 'Playtime' },
	{ Name = 'World.Events', Path = { 'World', 'Events' } },
	{ Name = 'Systems.Security', Path = { 'Systems', 'Security' } },
}

local function _requireEntry(entry: { Name: string, Path: { string }, Sub: string? }): any
	local node: any = ConfigFolder
	for _, seg in ipairs(entry.Path) do
		node = (node :: Folder):WaitForChild(seg)
	end
	local mod = require(node)
	if entry.Sub ~= nil then
		mod = (mod :: any)[entry.Sub]
	end
	return mod
end

-- Cross-config invariants: ladders must stay pegged and joins must
-- resolve. Each returns issue strings (empty = ok).
local function _checkInvariants(): { string }
	local issues: { string } = {}
	local ok, err = pcall(function()
		local Eggs = _requireEntry({ Name = 'x', Path = { 'Creatures', 'Eggs' } })
		local Animals = _requireEntry({ Name = 'x', Path = { 'Creatures', 'Animals' } })
		local Progression = _requireEntry({ Name = 'x', Path = { 'Creatures', 'Progression' } })
		local Rarity = _requireEntry({ Name = 'x', Path = { 'Creatures', 'Rarity' } })
		local Events = _requireEntry({ Name = 'x', Path = { 'World', 'Events' } })
		local Arena = _requireEntry({ Name = 'x', Path = { 'World', 'Arena' } })
		local Gear = _requireEntry({ Name = 'x', Path = { 'Economy', 'Gear' } })
		local Playtime = _requireEntry({ Name = 'x', Path = { 'Economy', 'Rewards' }, Sub = 'Playtime' })

		-- Ladder invariant: egg price == L1 sell value per rarity.
		if type(Eggs.Price) == 'table' and type(Animals.SellBaseValue) == 'table' then
			for rarity, price in pairs(Eggs.Price) do
				local sell = (Animals.SellBaseValue :: any)[rarity]
				if sell ~= nil and sell ~= price then
					issues[#issues + 1] = 'LADDER Eggs.Price['
						.. tostring(rarity)
						.. '] ('
						.. tostring(price)
						.. ') ~= Animals.SellBaseValue ('
						.. tostring(sell)
						.. ')'
				end
			end
		end

		-- Upgrade/XP single source: the exact-math cost in
		-- UpgradeService implements 28/25 == 1.12. If growth is
		-- retuned, the service fails loudly; this pins it here too.
		if (Progression.XP :: any).GrowthRate ~= 1.12 then
			issues[#issues + 1] = 'LADDER Progression.XP.GrowthRate ('
				.. tostring((Progression.XP :: any).GrowthRate)
				.. ') ~= 1.12 (UpgradeService exact math)'
		end

		-- Luck pool entries must all be known rarity tiers.
		local known: { [string]: boolean } = {}
		for _, tier in ipairs(Rarity.Order) do
			known[tier] = true
		end
		for i, tier in ipairs(Events.LuckPoolOrder) do
			if not known[tier] then
				issues[#issues + 1] = 'JOIN Events.LuckPoolOrder['
					.. tostring(i)
					.. '] ('
					.. tostring(tier)
					.. ') is not a Rarity.Order tier'
			end
		end

		-- Gear <-> Combat join: every combat entry resolves to a
		-- catalog gear with a matching Tool name.
		for _, entry in ipairs(Gear.Combat.All()) do
			local gear = Gear.FindGear(entry.GearId)
			if gear == nil then
				issues[#issues + 1] = 'JOIN Gear.Combat GearId=' .. tostring(entry.GearId) .. ' has no catalog entry'
			elseif gear.ToolName ~= entry.ToolName then
				issues[#issues + 1] = 'JOIN Gear.Combat GearId='
					.. tostring(entry.GearId)
					.. ' ToolName mismatch ('
					.. tostring(entry.ToolName)
					.. ' vs '
					.. tostring(gear.ToolName)
					.. ')'
			end
		end

		-- Preserved baseline pins (behavior regression tripwires).
		if Arena.ResultCardCap ~= 6 then
			issues[#issues + 1] = 'BASELINE Arena.ResultCardCap (' .. tostring(Arena.ResultCardCap) .. ') ~= 6'
		end
		if (Playtime.Settings :: any).DayBoundaryOffsetSeconds ~= 19800 then
			issues[#issues + 1] = 'BASELINE Rewards.Playtime day offset ('
				.. tostring((Playtime.Settings :: any).DayBoundaryOffsetSeconds)
				.. ') ~= 19800 (Asia/Kolkata)'
		end
		if Events.Transition.CoverSeconds ~= 0.65 then
			issues[#issues + 1] = 'BASELINE Events.Transition.CoverSeconds ('
				.. tostring(Events.Transition.CoverSeconds)
				.. ') ~= 0.65'
		end
	end)
	if not ok then
		issues[#issues + 1] = 'INVARIANT check crashed: ' .. tostring(err)
	end
	return issues
end

-- Run every domain Validate() + cross-config invariants.
-- Returns issue strings; empty = everything valid.
function ConfigValidator.ValidateAll(): { string }
	local issues: { string } = {}
	for _, entry in ipairs(_MODULES) do
		local ok, mod = pcall(_requireEntry, entry)
		if not ok then
			issues[#issues + 1] = entry.Name .. ': require failed: ' .. tostring(mod)
			continue
		end
		local vok, result = pcall(function()
			return (mod :: any).Validate()
		end)
		if not vok then
			issues[#issues + 1] = entry.Name .. '.Validate() crashed: ' .. tostring(result)
		elseif type(result) == 'table' then
			for _, issue in ipairs(result :: { string }) do
				issues[#issues + 1] = entry.Name .. '.' .. tostring(issue)
			end
		end
	end
	for _, issue in ipairs(_checkInvariants()) do
		issues[#issues + 1] = issue
	end
	return issues
end

-- Standard failure block for bad tunes.
function ConfigValidator.Report(issues: { string }): string
	local lines = { '[ConfigValidation] ' .. tostring(#issues) .. ' issue(s):' }
	for _, issue in ipairs(issues) do
		lines[#lines + 1] = '  - ' .. tostring(issue)
	end
	return table.concat(lines, '\n')
end

-- Fail fast with the full report (Studio). Bootstrap catches the
-- error and degrades to a warn in live servers.
function ConfigValidator.AssertValid()
	local issues = ConfigValidator.ValidateAll()
	if #issues > 0 then
		error(ConfigValidator.Report(issues), 2)
	end
end

return ConfigValidator
